import Foundation

final class BaselineCalibrationManager {
    static let shared = BaselineCalibrationManager()

    private let midpoint = 2.5
    private let lookbackSeconds = 300.0
    private let defaultCompositeThreshold = -1.5
    private let encoder = JSONEncoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    @discardableResult
    func calibrate(sessionDirectory: URL) -> PersonalBaselineProfile? {
        calibrate(
            sessionDirectories: [sessionDirectory],
            participantId: nil,
            outputSessionDirectory: sessionDirectory,
            resetTimestampS: nil,
            shouldPostStatus: true
        )
    }

    @discardableResult
    func calibrateParticipant(participantId: String, latestSessionDirectory: URL? = nil) -> PersonalBaselineProfile? {
        let sessionDirectories = DataRecordingManager.shared.personalisationSessionDirectories(participantId: participantId)
        return calibrate(
            sessionDirectories: sessionDirectories,
            participantId: participantId,
            outputSessionDirectory: latestSessionDirectory ?? sessionDirectories.last,
            resetTimestampS: personalisationResetTimestamp(for: participantId),
            shouldPostStatus: true
        )
    }

    func markFreshPersonalisationStart(participantId: String, timestampS: Double = Date().timeIntervalSince1970) {
        UserDefaults.standard.set(timestampS, forKey: resetTimestampKey(for: participantId))
        print("🧹 Personalisation baseline reset marker set for \(participantId) at \(timestampS)")
    }

    private func calibrate(
        sessionDirectories: [URL],
        participantId requestedParticipantId: String?,
        outputSessionDirectory: URL?,
        resetTimestampS: Double?,
        shouldPostStatus: Bool
    ) -> PersonalBaselineProfile? {
        let seqPolls = sessionDirectories.flatMap {
            readSEQPolls(from: $0.appendingPathComponent("seq_questionnaire.jsonl"), since: resetTimestampS)
        }
        let featureWindows = sessionDirectories.flatMap {
            readFeatureWindows(from: $0, since: resetTimestampS)
        }

        guard !seqPolls.isEmpty else {
            postStatusIfNeeded("Baseline skipped: no SEQ responses found.", didSucceed: false, shouldPostStatus: shouldPostStatus)
            print("⚠️ Baseline calibration skipped: no SEQ responses found")
            return nil
        }

        let neutralPolls = seqPolls.filter(\.isNeutral)
        let nonNeutralPolls = seqPolls.filter { !$0.isNeutral }

        guard !featureWindows.isEmpty else {
            let message = "Baseline skipped: \(seqPolls.count) SEQ response(s), \(neutralPolls.count) neutral, but no heart feature windows found."
            postStatusIfNeeded(message, didSucceed: false, shouldPostStatus: shouldPostStatus)
            print("⚠️ \(message)")
            return nil
        }

        guard !neutralPolls.isEmpty else {
            let message = "Baseline skipped: \(seqPolls.count) SEQ response(s), but none were neutral (stress and energy must both be >= \(midpoint))."
            postStatusIfNeeded(message, didSucceed: false, shouldPostStatus: shouldPostStatus)
            print("⚠️ \(message)")
            return nil
        }

        let neutralWindows = windows(from: featureWindows, linkedTo: neutralPolls)
        guard !neutralWindows.isEmpty else {
            let message = "Baseline skipped: \(neutralPolls.count) neutral SEQ response(s), but no heart windows in the \(Int(lookbackSeconds / 60))-minute lookback before submission."
            postStatusIfNeeded(message, didSucceed: false, shouldPostStatus: shouldPostStatus)
            print("⚠️ \(message)")
            return nil
        }

        let fullDayValues = valuesByFeature(from: featureWindows)
        let neutralValues = valuesByFeature(from: neutralWindows)

        var featureBaselines: [String: PersonalFeatureBaseline] = [:]
        for featureName in Self.featureNames {
            guard let neutralFeatureValues = neutralValues[featureName],
                  !neutralFeatureValues.isEmpty,
                  let fullFeatureValues = fullDayValues[featureName],
                  !fullFeatureValues.isEmpty
            else { continue }

            featureBaselines[featureName] = PersonalFeatureBaseline(
                mean: mean(neutralFeatureValues),
                standardDeviation: standardDeviation(neutralFeatureValues),
                rangeMinimum: fullFeatureValues.min() ?? .nan,
                rangeMaximum: fullFeatureValues.max() ?? .nan,
                neutralWindowCount: neutralFeatureValues.count,
                fullDayWindowCount: fullFeatureValues.count
            )
        }

        guard !featureBaselines.isEmpty else {
            let message = "Baseline skipped: neutral-linked heart windows were found, but none contained usable heart features."
            postStatusIfNeeded(message, didSucceed: false, shouldPostStatus: shouldPostStatus)
            print("⚠️ \(message)")
            return nil
        }

        let calibratedThreshold = calibratedCompositeThreshold(
            neutralWindows: neutralWindows,
            nonNeutralWindows: windows(from: featureWindows, linkedTo: nonNeutralPolls),
            baselines: featureBaselines
        )

        let profile = PersonalBaselineProfile(
            participantId: requestedParticipantId ?? participantId(from: seqPolls),
            sourceSessionDirectory: sourceSessionDescription(from: sessionDirectories),
            createdAtS: Date().timeIntervalSince1970,
            seqMidpoint: midpoint,
            neutralPollCount: neutralPolls.count,
            nonNeutralPollCount: nonNeutralPolls.count,
            lookbackSeconds: lookbackSeconds,
            defaultCompositeThreshold: defaultCompositeThreshold,
            calibratedCompositeThreshold: calibratedThreshold,
            features: featureBaselines
        )

        if let outputSessionDirectory {
            write(profile, to: outputSessionDirectory.appendingPathComponent("baseline_profile.json"))
            write(profile, to: participantProfileURL(for: outputSessionDirectory))
        }

        let message = "Heart-only baseline created from \(neutralPolls.count) neutral SEQ poll(s) across \(sessionDirectories.count) session(s)."
        postStatusIfNeeded(message, didSucceed: true, shouldPostStatus: shouldPostStatus)
        print("✅ \(message) threshold=\(String(format: "%.3f", calibratedThreshold))")
        return profile
    }

    func recoverUnfinishedPersonalisationSessions(participantId: String? = nil) -> BaselineRecoveryResult {
        let allSessionDirectories = DataRecordingManager.shared.personalisationSessionDirectories(participantId: participantId)
        let resetTimestampS = participantId.flatMap(personalisationResetTimestamp)
        let unfinishedSessionDirectories = allSessionDirectories
            .filter { sessionDirectory in
                !FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("baseline_profile.json").path)
            }

        let profile = calibrate(
            sessionDirectories: allSessionDirectories,
            participantId: participantId,
            outputSessionDirectory: allSessionDirectories.last,
            resetTimestampS: resetTimestampS,
            shouldPostStatus: false
        )

        return BaselineRecoveryResult(
            candidateSessionCount: unfinishedSessionDirectories.count,
            recoveredProfileCount: profile == nil ? 0 : 1
        )
    }

    private func readSEQPolls(from url: URL, since resetTimestampS: Double?) -> [SEQPoll] {
        readJSONLines(from: url).compactMap { row in
            guard let submittedAtS = double(row["submittedAtS"]),
                  let stressScore = double(row["stressScore"]),
                  let energyScore = double(row["energyScore"])
            else { return nil }
            if let resetTimestampS, submittedAtS < resetTimestampS {
                return nil
            }

            return SEQPoll(
                submittedAtS: submittedAtS,
                participantId: row["participantId"] as? String,
                stressScore: stressScore,
                energyScore: energyScore,
                // Higher SEQ Stress score means lower perceived strain after reverse scoring tense/stressed/pressured items.
                isNeutral: stressScore >= midpoint && energyScore >= midpoint
            )
        }
    }

    private func readFeatureWindows(from sessionDirectory: URL, since resetTimestampS: Double?) -> [FeatureWindow] {
        return readJSONLines(from: sessionDirectory.appendingPathComponent("heart_features.jsonl"))
            .compactMap { row -> FeatureWindow? in
                guard let windowEndS = double(row["windowEndS"]) else { return nil }
                if let resetTimestampS, windowEndS < resetTimestampS {
                    return nil
                }
                return FeatureWindow(
                    windowEndS: windowEndS,
                    values: [
                        "hrMean": double(row["hrMean"]),
                        "hrvMean": double(row["hrvMean"]) ?? double(row["sdnnProxy"]),
                        "hrSlope": double(row["hrSlope"])
                    ].compactMapValues { $0 }
                )
            }
    }

    private func windows(from featureWindows: [FeatureWindow], linkedTo polls: [SEQPoll]) -> [FeatureWindow] {
        guard !polls.isEmpty else { return [] }

        return featureWindows.filter { window in
            polls.contains { poll in
                window.windowEndS > poll.submittedAtS - lookbackSeconds &&
                window.windowEndS <= poll.submittedAtS
            }
        }
    }

    private func valuesByFeature(from windows: [FeatureWindow]) -> [String: [Double]] {
        var output: [String: [Double]] = [:]

        for window in windows {
            for (featureName, value) in window.values where value.isFinite {
                output[featureName, default: []].append(value)
            }
        }

        return output
    }

    private func calibratedCompositeThreshold(
        neutralWindows: [FeatureWindow],
        nonNeutralWindows: [FeatureWindow],
        baselines: [String: PersonalFeatureBaseline]
    ) -> Double {
        let neutralScores = compositeScores(for: neutralWindows, baselines: baselines)
        let nonNeutralScores = compositeScores(for: nonNeutralWindows, baselines: baselines)

        guard !neutralScores.isEmpty, !nonNeutralScores.isEmpty else {
            return defaultCompositeThreshold
        }

        let candidates = (neutralScores + nonNeutralScores)
            .sorted()
            .adjacentPairs()
            .map { ($0 + $1) / 2.0 }

        guard !candidates.isEmpty else {
            return defaultCompositeThreshold
        }

        let best = candidates.max { lhs, rhs in
            separationScore(threshold: lhs, neutralScores: neutralScores, nonNeutralScores: nonNeutralScores) <
            separationScore(threshold: rhs, neutralScores: neutralScores, nonNeutralScores: nonNeutralScores)
        }

        return best ?? defaultCompositeThreshold
    }

    private func compositeScores(for windows: [FeatureWindow], baselines: [String: PersonalFeatureBaseline]) -> [Double] {
        windows.compactMap { window in
            let zScores = window.values.compactMap { featureName, value -> Double? in
                guard let baseline = baselines[featureName],
                      baseline.standardDeviation.isFinite,
                      baseline.standardDeviation > 0,
                      value.isFinite
                else { return nil }

                let direction = Self.featureDirections[featureName] ?? 1.0
                return direction * ((value - baseline.mean) / baseline.standardDeviation)
            }

            guard !zScores.isEmpty else { return nil }
            return mean(zScores)
        }
    }

    private func separationScore(threshold: Double, neutralScores: [Double], nonNeutralScores: [Double]) -> Double {
        let neutralCorrect = neutralScores.filter { $0 >= threshold }.count
        let nonNeutralCorrect = nonNeutralScores.filter { $0 < threshold }.count
        let neutralRate = Double(neutralCorrect) / Double(neutralScores.count)
        let nonNeutralRate = Double(nonNeutralCorrect) / Double(nonNeutralScores.count)
        return (neutralRate + nonNeutralRate) / 2.0
    }

    private func readJSONLines(from url: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        return content
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return row
            }
    }

    private func write(_ profile: PersonalBaselineProfile, to url: URL) {
        do {
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
        } catch {
            print("❌ Could not write baseline profile:", error.localizedDescription)
        }
    }

    private func postStatusIfNeeded(_ message: String, didSucceed: Bool, shouldPostStatus: Bool) {
        guard shouldPostStatus else { return }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .baselineCalibrationStatusChanged,
                object: nil,
                userInfo: [
                    "message": message,
                    "didSucceed": didSucceed
                ]
            )
        }
    }

    private func participantProfileURL(for sessionDirectory: URL) -> URL {
        let modeDirectoryNames = Set(StudyRecordingMode.allCases.map(\.rawValue))
        let parent = sessionDirectory.deletingLastPathComponent()

        if modeDirectoryNames.contains(parent.lastPathComponent) {
            return parent
                .deletingLastPathComponent()
                .appendingPathComponent("baseline_profile.json")
        }

        return parent
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("baseline_profile.json")
    }

    private func participantId(from polls: [SEQPoll]) -> String {
        polls.compactMap(\.participantId).first ?? "participant"
    }

    private func sourceSessionDescription(from sessionDirectories: [URL]) -> String {
        guard sessionDirectories.count != 1 else {
            return sessionDirectories[0].lastPathComponent
        }

        return "multiple_personalisation_sessions_\(sessionDirectories.count)"
    }

    private func resetTimestampKey(for participantId: String) -> String {
        "personalisationBaselineResetAtS.\(participantId)"
    }

    private func personalisationResetTimestamp(for participantId: String) -> Double? {
        UserDefaults.standard.object(forKey: resetTimestampKey(for: participantId)) as? Double
    }

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let doubleValue = Double(value), doubleValue.isFinite { return doubleValue }
        return nil
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }

        let mu = mean(values)
        let variance = values.reduce(0) { total, value in
            let diff = value - mu
            return total + diff * diff
        } / Double(values.count)

        return sqrt(variance)
    }

    private static let featureNames = [
        "hrMean",
        "hrvMean",
        "hrSlope"
    ]

    private static let featureDirections: [String: Double] = [
        "hrMean": 1,
        "hrvMean": -1,
        "hrSlope": 1
    ]

}

private struct SEQPoll {
    let submittedAtS: Double
    let participantId: String?
    let stressScore: Double
    let energyScore: Double
    let isNeutral: Bool
}

private struct FeatureWindow {
    let windowEndS: Double
    let values: [String: Double]
}

struct BaselineRecoveryResult {
    let candidateSessionCount: Int
    let recoveredProfileCount: Int
}

extension Notification.Name {
    static let baselineCalibrationStatusChanged = Notification.Name("baselineCalibrationStatusChanged")
}

private extension Array where Element == Double {
    func adjacentPairs() -> [(Double, Double)] {
        guard count > 1 else { return [] }
        return zip(dropLast(), dropFirst()).map { ($0, $1) }
    }
}
