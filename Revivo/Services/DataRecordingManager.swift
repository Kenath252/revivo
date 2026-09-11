import Foundation

enum StudyRecordingMode: String, Codable, CaseIterable {
    case personalisation
    case interaction
    case baseline
}

enum RecordingExportError: LocalizedError {
    case noRecordedFiles

    var errorDescription: String? {
        switch self {
        case .noRecordedFiles:
            return "No recorded data files were found."
        }
    }
}

final class DataRecordingManager {
    static let shared = DataRecordingManager()

    private let queue = DispatchQueue(label: "Revivo.dataRecording", qos: .utility)
    private let encoder = JSONEncoder()
    private var activeSession: RecordingSession?

    private init() {
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    func start(mode: StudyRecordingMode, participantId: String = "participant") {
        queue.async {
            if let activeSession = self.activeSession,
               activeSession.mode == mode,
               activeSession.participantId == participantId {
                return
            }

            let dayId = Self.dayFormatter.string(from: Date())
            let sessionId = Self.sessionFormatter.string(from: Date())
            let directory = self.baseDirectory()
                .appendingPathComponent(participantId, isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
                .appendingPathComponent(dayId, isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.activeSession = RecordingSession(
                    mode: mode,
                    participantId: participantId,
                    sessionId: sessionId,
                    directory: directory
                )
                self.writeSessionStartMarkers()
                print("💾 Recording \(mode.rawValue) data to \(directory.path)")
            } catch {
                print("❌ Could not start \(mode.rawValue) recording:", error.localizedDescription)
            }
        }
    }

    func stop(
        buildBaseline: Bool = false,
        participantIdForBaseline: String? = nil,
        writeDailySummary: Bool = false,
        summarySource: String = "stop"
    ) {
        queue.async {
            guard let activeSession = self.activeSession else {
                if buildBaseline, let participantIdForBaseline {
                    BaselineCalibrationManager.shared.calibrateParticipant(participantId: participantIdForBaseline)
                }
                return
            }

            self.appendJSONLine(
                [
                    "event": "recordingStopped",
                    "sessionId": activeSession.sessionId,
                    "timestampS": Date().timeIntervalSince1970
                ],
                to: activeSession.eventsURL
            )
            self.activeSession = nil
            print("💾 Stopped recording data")

            if writeDailySummary {
                self.appendDailySummary(for: activeSession, source: summarySource)
            }

            if buildBaseline, activeSession.mode == .personalisation {
                BaselineCalibrationManager.shared.calibrateParticipant(
                    participantId: activeSession.participantId,
                    latestSessionDirectory: activeSession.directory
                )
            }
        }
    }

    func recordHeartWindow(_ window: HeartFeatureWindow) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "sessionId": activeSession.sessionId,
                    "windowStartS": self.jsonValue(window.windowStartS),
                    "windowEndS": self.jsonValue(window.windowEndS),
                    "hrMean": self.jsonValue(window.hrMean),
                    "hrvMean": self.jsonValue(window.hrvMean),
                    "sdnnProxy": self.jsonValue(window.sdnnProxy),
                    "hrSlope": self.jsonValue(window.hrSlope)
                ],
                to: activeSession.heartFeaturesURL
            )
        }
    }

    func recordSEQResponse(
        responses: [String: Int],
        stressScore: Double,
        energyScore: Double,
        promptedAtS: Double,
        submittedAtS: Double
    ) {
        queue.async {
            guard let activeSession = self.activeSession else {
                print("⚠️ SEQ response not saved: no active recording session")
                return
            }
            self.appendJSONLine(
                [
                    "questionnaire": "SEQ",
                    "sessionId": activeSession.sessionId,
                    "timeframe": "last_30_minutes",
                    "mode": activeSession.mode.rawValue,
                    "participantId": activeSession.participantId,
                    "promptedAtS": promptedAtS,
                    "submittedAtS": submittedAtS,
                    "responses": responses,
                    "stressScore": self.jsonValue(stressScore),
                    "energyScore": self.jsonValue(energyScore)
                ],
                to: activeSession.seqQuestionnaireURL
            )
            print("📝 SEQ response saved mode=\(activeSession.mode.rawValue) session=\(activeSession.sessionId) stress=\(String(format: "%.2f", stressScore)) energy=\(String(format: "%.2f", energyScore))")
        }
    }

    func recordDeskActivityEvent(
        isWorkingAtDesk: Bool,
        accumulatedDeskWorkSeconds: TimeInterval,
        currentDeskBoutSeconds: TimeInterval,
        confidence: Double,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "deskActivity",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "isWorkingAtDesk": isWorkingAtDesk,
                    "accumulatedDeskWorkSeconds": self.jsonValue(accumulatedDeskWorkSeconds),
                    "currentDeskBoutSeconds": self.jsonValue(currentDeskBoutSeconds),
                    "confidence": self.jsonValue(confidence)
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordDeskBoutResetEvent(
        previousDeskBoutSeconds: TimeInterval,
        accumulatedDeskWorkSeconds: TimeInterval,
        reason: String,
        source: String,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "deskBoutReset",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "previousDeskBoutSeconds": self.jsonValue(previousDeskBoutSeconds),
                    "accumulatedDeskWorkSeconds": self.jsonValue(accumulatedDeskWorkSeconds),
                    "reason": reason,
                    "source": source
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordDeskBoutLifecycleEvent(
        event: String,
        currentDeskBoutSeconds: TimeInterval,
        accumulatedDeskWorkSeconds: TimeInterval,
        reason: String,
        source: String,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": event,
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "currentDeskBoutSeconds": self.jsonValue(currentDeskBoutSeconds),
                    "accumulatedDeskWorkSeconds": self.jsonValue(accumulatedDeskWorkSeconds),
                    "reason": reason,
                    "source": source
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordCalendarAvailabilityEvent(
        isInMeeting: Bool,
        meetingTitle: String?,
        meetingEndsAtS: Double?,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "calendarAvailability",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "isInMeeting": isInMeeting,
                    "meetingTitle": meetingTitle ?? NSNull(),
                    "meetingEndsAtS": meetingEndsAtS.map(self.jsonValue) ?? NSNull()
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordBaselineBreakNotification(
        breakId: String,
        title: String,
        body: String,
        deliveredToPhone: Bool,
        deliveredToWatch: Bool,
        timeoutSeconds: TimeInterval,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "baselineBreakNotification",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "breakId": breakId,
                    "title": title,
                    "body": body,
                    "deliveredToPhone": deliveredToPhone,
                    "deliveredToWatch": deliveredToWatch,
                    "timeoutSeconds": self.jsonValue(timeoutSeconds)
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordBaselineBreakResponse(
        breakId: String,
        response: String,
        source: String,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "baselineBreakResponse",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "breakId": breakId,
                    "response": response,
                    "source": source
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordInteractionInvitation(
        invitationId: String,
        windowSeconds: TimeInterval,
        holdSeconds: TimeInterval,
        objectDetectedAtStart: Bool,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "interactionInvitation",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "invitationId": invitationId,
                    "windowSeconds": self.jsonValue(windowSeconds),
                    "holdSeconds": self.jsonValue(holdSeconds),
                    "objectDetectedAtStart": objectDetectedAtStart
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordInteractionInvitationResponse(
        invitationId: String,
        response: String,
        source: String,
        reason: String?,
        tofUpdateCount: Int,
        tofTrueCount: Int,
        tofFalseCount: Int,
        timestampS: Double = Date().timeIntervalSince1970
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            self.appendJSONLine(
                [
                    "event": "interactionInvitationResponse",
                    "sessionId": activeSession.sessionId,
                    "timestampS": self.jsonValue(timestampS),
                    "invitationId": invitationId,
                    "response": response,
                    "source": source,
                    "reason": reason ?? NSNull(),
                    "tofUpdateCount": tofUpdateCount,
                    "tofTrueCount": tofTrueCount,
                    "tofFalseCount": tofFalseCount
                ],
                to: activeSession.eventsURL
            )
        }
    }

    func recordActiveBreakQuestionnaireResponse(
        mode: String,
        breakDurationSeconds: TimeInterval,
        physicalActivity: String?,
        interactionPosture: String?,
        questionnaireResponses: [[String: Any]],
        promptedAtS: Double,
        submittedAtS: Double
    ) {
        queue.async {
            guard let activeSession = self.activeSession else { return }
            let trimmedPhysicalActivity = physicalActivity?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let physicalActivityValue: Any = trimmedPhysicalActivity?.isEmpty == false
                ? trimmedPhysicalActivity as Any
                : NSNull()
            let trimmedInteractionPosture = interactionPosture?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let interactionPostureValue: Any = trimmedInteractionPosture?.isEmpty == false
                ? trimmedInteractionPosture as Any
                : NSNull()
            self.appendJSONLine(
                [
                    "event": "activeBreakQuestionnaireResponse",
                    "sessionId": activeSession.sessionId,
                    "mode": mode,
                    "participantId": activeSession.participantId,
                    "breakDurationSeconds": self.jsonValue(breakDurationSeconds),
                    "physicalActivity": physicalActivityValue,
                    "interactionPosture": interactionPostureValue,
                    "promptedAtS": self.jsonValue(promptedAtS),
                    "submittedAtS": self.jsonValue(submittedAtS),
                    "questionnaires": questionnaireResponses
                ],
                to: activeSession.activeBreakQuestionnaireURL
            )
        }
    }

    func currentRecordingDirectory() -> URL? {
        queue.sync {
            activeSession?.directory
        }
    }

    func currentRecordingMode() -> StudyRecordingMode? {
        queue.sync {
            activeSession?.mode
        }
    }

    func allRecordedFiles(participantId: String? = nil) -> [URL] {
        let root = participantId
            .map { baseDirectory().appendingPathComponent($0, isDirectory: true) }
            ?? baseDirectory()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { ["json", "jsonl"].contains($0.pathExtension.lowercased()) }
    }

    func prepareRecordedDataExport(participantId: String? = nil) throws -> [URL] {
        let files = allRecordedFiles(participantId: participantId).sorted { $0.path < $1.path }
        guard !files.isEmpty else {
            throw RecordingExportError.noRecordedFiles
        }

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevivoExport-\(Self.exportFormatter.string(from: Date()))", isDirectory: true)

        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let rootPath = baseDirectory().path
        for sourceURL in files {
            let relativePath = sourceURL.path
                .replacingOccurrences(of: rootPath, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destinationURL = exportDirectory.appendingPathComponent(relativePath)
            let destinationDirectory = destinationURL.deletingLastPathComponent()

            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        return [exportDirectory]
    }

    func baselineProfileURL(participantId: String) -> URL {
        baseDirectory()
            .appendingPathComponent(participantId, isDirectory: true)
            .appendingPathComponent("baseline_profile.json")
    }

    func loadBaselineProfile(participantId: String) -> PersonalBaselineProfile? {
        let url = baselineProfileURL(participantId: participantId)
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            return try JSONDecoder().decode(PersonalBaselineProfile.self, from: data)
        } catch {
            print("❌ Could not decode baseline profile:", error.localizedDescription)
            return nil
        }
    }

    func personalisationSessionDirectories(participantId: String? = nil) -> [URL] {
        let root = baseDirectory()
        let participantDirectories: [URL]

        if let participantId, !participantId.isEmpty {
            participantDirectories = [root.appendingPathComponent(participantId, isDirectory: true)]
        } else {
            participantDirectories = directoryContents(of: root)
        }

        return participantDirectories.flatMap { participantDirectory in
            let personalisationDirectory = participantDirectory.appendingPathComponent("personalisation", isDirectory: true)
            return directoryContents(of: personalisationDirectory).flatMap { dayDirectory in
                let legacySessionDirectories = directoryContents(of: dayDirectory)
                    .filter(self.containsRecordingFiles)
                return self.containsRecordingFiles(dayDirectory)
                    ? [dayDirectory] + legacySessionDirectories
                    : legacySessionDirectories
            }
        }
        .sorted { $0.path < $1.path }
    }

    func recoverMissingDailySummaries(participantId: String? = nil) {
        queue.async {
            let today = Self.dayFormatter.string(from: Date())
            let root = participantId
                .map { self.baseDirectory().appendingPathComponent($0, isDirectory: true) }
                ?? self.baseDirectory()
            let participantDirectories: [URL]

            if participantId == nil {
                participantDirectories = self.directoryContents(of: root)
            } else {
                participantDirectories = [root]
            }

            for participantDirectory in participantDirectories {
                for mode in StudyRecordingMode.allCases {
                    let modeDirectory = participantDirectory.appendingPathComponent(mode.rawValue, isDirectory: true)
                    for dayDirectory in self.directoryContents(of: modeDirectory) {
                        guard dayDirectory.lastPathComponent < today,
                              self.containsRecordingFiles(dayDirectory),
                              self.readJSONLines(from: dayDirectory.appendingPathComponent("daily_summary.jsonl")).isEmpty
                        else { continue }

                        let session = RecordingSession(
                            mode: mode,
                            participantId: participantDirectory.lastPathComponent,
                            sessionId: "recovered-\(dayDirectory.lastPathComponent)",
                            directory: dayDirectory
                        )
                        self.appendDailySummary(for: session, source: "startupRecovery")
                    }
                }
            }
        }
    }

    private func writeSessionStartMarkers() {
        guard let activeSession else { return }
        let startedAtS = Date().timeIntervalSince1970
        let separator = String(repeating: ".", count: 72)
        let marker: [String: Any] = [
            "event": "sessionSeparator",
            "sessionId": activeSession.sessionId,
            "participantId": activeSession.participantId,
            "mode": activeSession.mode.rawValue,
            "startedAtS": startedAtS,
            "separator": separator
        ]

        let metadata: [String: Any] = [
            "event": "sessionStarted",
            "sessionId": activeSession.sessionId,
            "participantId": activeSession.participantId,
            "mode": activeSession.mode.rawValue,
            "startedAtS": startedAtS,
            "dayDirectory": activeSession.directory.lastPathComponent
        ]

        appendJSONLine(marker, to: activeSession.eventsURL)
        appendJSONLine(metadata, to: activeSession.eventsURL)
        appendJSONLine(marker, to: activeSession.heartFeaturesURL)
        appendJSONLine(marker, to: activeSession.seqQuestionnaireURL)
        appendJSONLine(marker, to: activeSession.activeBreakQuestionnaireURL)
    }

    private func appendDailySummary(for session: RecordingSession, source: String) {
        let generatedAtS = Date().timeIntervalSince1970
        let events = readJSONLines(from: session.eventsURL)
        let activeBreakRows = readJSONLines(from: session.activeBreakQuestionnaireURL)
        let existingSummaries = readJSONLines(from: session.dailySummaryURL)
        let revision = existingSummaries.count + 1
        let sessionIds = uniqueStrings(from: events + activeBreakRows, key: "sessionId")
        let deskWorkValues = events.compactMap { double($0["accumulatedDeskWorkSeconds"]) }
        let finalBoutSeconds = events.compactMap { double($0["currentDeskBoutSeconds"]) }.last ?? 0
        let activeBreakDurations = activeBreakRows.compactMap { double($0["breakDurationSeconds"]) }
        let baselineResponses = events.filter { ($0["event"] as? String) == "baselineBreakResponse" }
        let interactionInvitations = events.filter { ($0["event"] as? String) == "interactionInvitation" }
        let interactionResponses = events.filter { ($0["event"] as? String) == "interactionInvitationResponse" }
        let firstSessionStartedAtS = events.compactMap { double($0["startedAtS"]) }.min()
        let lastRecordingStoppedAtS = events.compactMap { double($0["timestampS"]) }.max()
        let baselineNotificationCount = events.filter { ($0["event"] as? String) == "baselineBreakNotification" }.count
        let baselineAcceptedCount = baselineResponses.filter { ($0["response"] as? String) == "accepted" }.count
        let baselineRejectedCount = baselineResponses.filter { ($0["response"] as? String) == "rejected" }.count
        let baselineTimedOutCount = baselineResponses.filter { ($0["response"] as? String) == "timedOut" }.count
        let interactionAcceptedCount = interactionResponses.filter { ($0["response"] as? String) == "accepted" }.count
        let interactionRejectedCount = interactionResponses.filter { ($0["response"] as? String) == "rejected" }.count

        let row: [String: Any] = [
            "event": "dailySummary",
            "participantId": session.participantId,
            "mode": session.mode.rawValue,
            "day": session.directory.lastPathComponent,
            "summaryRevision": revision,
            "supersedesRevision": revision > 1 ? revision - 1 : NSNull(),
            "isLatestAtWriteTime": true,
            "source": source,
            "generatedAtS": jsonValue(generatedAtS),
            "sessionIds": sessionIds,
            "sessionCount": sessionIds.count,
            "firstSessionStartedAtS": jsonValue(firstSessionStartedAtS ?? .nan),
            "lastRecordingStoppedAtS": jsonValue(lastRecordingStoppedAtS ?? .nan),
            "totalDeskWorkSeconds": jsonValue(deskWorkValues.max() ?? 0),
            "finalCurrentDeskBoutSeconds": jsonValue(finalBoutSeconds),
            "totalActiveBreakSeconds": jsonValue(activeBreakDurations.reduce(0, +)),
            "activeBreakCount": activeBreakDurations.count,
            "baselineNotificationCount": baselineNotificationCount,
            "baselineAcceptedCount": baselineAcceptedCount,
            "baselineRejectedCount": baselineRejectedCount,
            "baselineTimedOutCount": baselineTimedOutCount,
            "interactionInvitationCount": interactionInvitations.count,
            "interactionAcceptedCount": interactionAcceptedCount,
            "interactionRejectedCount": interactionRejectedCount
        ]

        appendJSONLine(row, to: session.dailySummaryURL)
        print("📘 Daily summary written mode=\(session.mode.rawValue) day=\(session.directory.lastPathComponent) revision=\(revision)")
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to fileURL: URL) {
        do {
            let data = try encoder.encode(value)
            append(data + Data([0x0A]), to: fileURL)
        } catch {
            print("❌ Could not encode recording row:", error.localizedDescription)
        }
    }

    private func appendJSONLine(_ dictionary: [String: Any], to fileURL: URL) {
        guard JSONSerialization.isValidJSONObject(dictionary) else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            append(data + Data([0x0A]), to: fileURL)
        } catch {
            print("❌ Could not encode recording event:", error.localizedDescription)
        }
    }

    private func jsonValue(_ value: Double) -> Any {
        value.isFinite ? value : NSNull()
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

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let doubleValue = Double(value), doubleValue.isFinite { return doubleValue }
        return nil
    }

    private func uniqueStrings(from rows: [[String: Any]], key: String) -> [String] {
        Array(Set(rows.compactMap { $0[key] as? String })).sorted()
    }

    private func append(_ data: Data, to fileURL: URL) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                print("❌ Could not append recording file:", error.localizedDescription)
            }
        } else {
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("❌ Could not create recording file:", error.localizedDescription)
            }
        }
    }

    private func baseDirectory() -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("StudyRecordings", isDirectory: true)
    }

    private func directoryContents(of url: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.filter { fileURL in
            (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func containsRecordingFiles(_ url: URL) -> Bool {
        ["events.jsonl", "heart_features.jsonl", "seq_questionnaire.jsonl"]
            .contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    private static let exportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

private struct RecordingSession {
    let mode: StudyRecordingMode
    let participantId: String
    let sessionId: String
    let directory: URL

    var heartFeaturesURL: URL {
        directory.appendingPathComponent("heart_features.jsonl")
    }

    var eventsURL: URL {
        directory.appendingPathComponent("events.jsonl")
    }

    var seqQuestionnaireURL: URL {
        directory.appendingPathComponent("seq_questionnaire.jsonl")
    }

    var activeBreakQuestionnaireURL: URL {
        directory.appendingPathComponent("active_break_questionnaire.jsonl")
    }

    var dailySummaryURL: URL {
        directory.appendingPathComponent("daily_summary.jsonl")
    }
}
