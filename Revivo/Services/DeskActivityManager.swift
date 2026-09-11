import Foundation

final class DeskActivityManager: ObservableObject {
    static let shared = DeskActivityManager()

    @Published private(set) var isWorkingAtDesk = false
    @Published private(set) var accumulatedDeskWorkSeconds: TimeInterval = 0
    @Published private(set) var currentDeskBoutSeconds: TimeInterval = 0
    @Published private(set) var isBoutPaused = false
    @Published private(set) var latestConfidence: Double = 0

    private let evaluationWindowSeconds: TimeInterval = 12
    private let snapshotIntervalSeconds: TimeInterval = 30
    private let minimumSamplesPerWindow = 20
    private let deskAccelMeanThreshold = 0.25
    private let deskAccelPeakThreshold = 1.60
    private let deskAttitudeRangeThreshold = 1.40
    private let strongMotionAccelMeanThreshold = 0.55
    private let strongMotionAccelPeakThreshold = 2.40
    private let strongMotionAttitudeRangeThreshold = 2.40
    private let deskEntryWindowCount = 2
    private let deskExitGraceSeconds: TimeInterval = 90
    private let strongMotionExitGraceSeconds: TimeInterval = 30

    private var samples: [IMUData] = []
    private var isTracking = false
    private var lastSampleTimestampS: Double?
    private var currentBoutStartedAtS: Double?
    private var lastSnapshotAtS: Double = 0
    private var consecutiveDeskWindows = 0
    private var nonDeskStartedAtS: Double?
    private var strongMotionStartedAtS: Double?
    private var pauseStartedAtS: Double?

    private init() {
        refreshDailyTotalIfNeeded()
    }

    func setTrackingEnabled(_ isEnabled: Bool, reset: Bool = false) {
        isTracking = isEnabled
        if reset {
            resetInteractionState()
        }
        refreshDailyTotalIfNeeded()
        if !isEnabled {
            lastSampleTimestampS = nil
            latestConfidence = 0
        }
    }

    func resetSession() {
        resetInteractionState()
    }

    func refreshDailyTotal() {
        refreshDailyTotalIfNeeded()
    }

    var displayCurrentDeskBoutSeconds: TimeInterval {
        guard isWorkingAtDesk,
              !isBoutPaused,
              let currentBoutStartedAtS
        else {
            return currentDeskBoutSeconds
        }

        return max(currentDeskBoutSeconds, Date().timeIntervalSince1970 - currentBoutStartedAtS)
    }

    func pauseCurrentBout(reason: String, source: String, timestampS: Double = Date().timeIntervalSince1970) {
        refreshDailyTotalIfNeeded(timestampS: timestampS)
        guard !isBoutPaused else { return }

        if isWorkingAtDesk, let currentBoutStartedAtS {
            currentDeskBoutSeconds = max(0, timestampS - currentBoutStartedAtS)
        }

        isBoutPaused = true
        pauseStartedAtS = timestampS
        lastSampleTimestampS = nil

        DataRecordingManager.shared.recordDeskBoutLifecycleEvent(
            event: "deskBoutPaused",
            currentDeskBoutSeconds: currentDeskBoutSeconds,
            accumulatedDeskWorkSeconds: accumulatedDeskWorkSeconds,
            reason: reason,
            source: source,
            timestampS: timestampS
        )
        print("🪑 Desk bout paused reason=\(reason) source=\(source) current=\(Int(currentDeskBoutSeconds))s")
    }

    func resumeCurrentBout(reason: String, source: String, timestampS: Double = Date().timeIntervalSince1970) {
        refreshDailyTotalIfNeeded(timestampS: timestampS)
        guard isBoutPaused else { return }

        isBoutPaused = false
        pauseStartedAtS = nil
        lastSampleTimestampS = timestampS
        if isWorkingAtDesk {
            currentBoutStartedAtS = timestampS - currentDeskBoutSeconds
        }

        DataRecordingManager.shared.recordDeskBoutLifecycleEvent(
            event: "deskBoutResumed",
            currentDeskBoutSeconds: currentDeskBoutSeconds,
            accumulatedDeskWorkSeconds: accumulatedDeskWorkSeconds,
            reason: reason,
            source: source,
            timestampS: timestampS
        )
        print("🪑 Desk bout resumed reason=\(reason) source=\(source) current=\(Int(currentDeskBoutSeconds))s")
    }

    func resetCurrentBout(reason: String, source: String, timestampS: Double = Date().timeIntervalSince1970) {
        refreshDailyTotalIfNeeded(timestampS: timestampS)
        let previousBoutSeconds = currentDeskBoutSeconds
        DataRecordingManager.shared.recordDeskBoutResetEvent(
            previousDeskBoutSeconds: previousBoutSeconds,
            accumulatedDeskWorkSeconds: accumulatedDeskWorkSeconds,
            reason: reason,
            source: source,
            timestampS: timestampS
        )
        resetInteractionState()
        print("🪑 Desk bout reset reason=\(reason) source=\(source) previous=\(Int(previousBoutSeconds))s")
    }

    private func resetInteractionState() {
        samples.removeAll()
        currentDeskBoutSeconds = 0
        isBoutPaused = false
        latestConfidence = 0
        isWorkingAtDesk = false
        lastSampleTimestampS = nil
        currentBoutStartedAtS = nil
        lastSnapshotAtS = 0
        consecutiveDeskWindows = 0
        nonDeskStartedAtS = nil
        strongMotionStartedAtS = nil
        pauseStartedAtS = nil
    }

    func ingest(_ imu: IMUData) {
        guard isTracking else { return }
        refreshDailyTotalIfNeeded(timestampS: imu.timestampS)

        if isBoutPaused {
            lastSampleTimestampS = imu.timestampS
            return
        }

        if isWorkingAtDesk, let lastSampleTimestampS {
            let delta = max(0, min(imu.timestampS - lastSampleTimestampS, 2.0))
            addDeskWorkSeconds(delta, timestampS: imu.timestampS)
            if let currentBoutStartedAtS {
                currentDeskBoutSeconds = max(0, imu.timestampS - currentBoutStartedAtS)
            }
        }
        lastSampleTimestampS = imu.timestampS

        samples.append(imu)
        samples.removeAll { imu.timestampS - $0.timestampS > evaluationWindowSeconds }
        evaluateWindow(currentTimeS: imu.timestampS)
        recordSnapshotIfNeeded(currentTimeS: imu.timestampS)
    }

    private func evaluateWindow(currentTimeS: Double) {
        guard samples.count >= minimumSamplesPerWindow else { return }

        let accelMagnitudes = samples.map { sample in
            sqrt(sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az)
        }
        let accelMean = mean(accelMagnitudes)
        let accelPeak = accelMagnitudes.max() ?? 0
        let attitudeRange = max(range(samples.map(\.roll)), range(samples.map(\.pitch)), range(samples.map(\.yaw)))

        let accelMeanScore = 1 - min(accelMean / strongMotionAccelMeanThreshold, 1)
        let accelPeakScore = 1 - min(accelPeak / strongMotionAccelPeakThreshold, 1)
        let attitudeScore = 1 - min(attitudeRange / strongMotionAttitudeRangeThreshold, 1)
        latestConfidence = max(0, min((accelMeanScore + accelPeakScore + attitudeScore) / 3, 1))

        let deskSignals = [
            accelMean <= deskAccelMeanThreshold,
            accelPeak <= deskAccelPeakThreshold,
            attitudeRange <= deskAttitudeRangeThreshold
        ].filter { $0 }.count

        let strongMotion =
            accelMean >= strongMotionAccelMeanThreshold ||
            accelPeak >= strongMotionAccelPeakThreshold ||
            attitudeRange >= strongMotionAttitudeRangeThreshold

        let deskCandidate = deskSignals >= 2 && !strongMotion
        updateDeskState(
            candidate: deskCandidate,
            strongMotion: strongMotion,
            currentTimeS: currentTimeS
        )
        let nonDeskDuration = nonDeskStartedAtS.map { currentTimeS - $0 } ?? 0
        let strongMotionDuration = strongMotionStartedAtS.map { currentTimeS - $0 } ?? 0
        print("🪑 Desk window accelMean=\(String(format: "%.3f", accelMean)) accelPeak=\(String(format: "%.3f", accelPeak)) attitudeRange=\(String(format: "%.3f", attitudeRange)) deskSignals=\(deskSignals)/3 strongMotion=\(strongMotion) nonDeskFor=\(Int(nonDeskDuration))s strongMotionFor=\(Int(strongMotionDuration))s confidence=\(String(format: "%.2f", latestConfidence))")
    }

    private func updateDeskState(candidate: Bool, strongMotion: Bool, currentTimeS: Double) {
        if candidate {
            consecutiveDeskWindows += 1
            nonDeskStartedAtS = nil
            strongMotionStartedAtS = nil
        } else {
            consecutiveDeskWindows = 0
            if nonDeskStartedAtS == nil {
                nonDeskStartedAtS = currentTimeS
            }

            if strongMotion {
                if strongMotionStartedAtS == nil {
                    strongMotionStartedAtS = currentTimeS
                }
            } else {
                strongMotionStartedAtS = nil
            }
        }

        let nextIsWorkingAtDesk: Bool
        if isWorkingAtDesk {
            let nonDeskDuration = nonDeskStartedAtS.map { currentTimeS - $0 } ?? 0
            let strongMotionDuration = strongMotionStartedAtS.map { currentTimeS - $0 } ?? 0
            nextIsWorkingAtDesk =
                nonDeskDuration < deskExitGraceSeconds &&
                strongMotionDuration < strongMotionExitGraceSeconds
        } else {
            nextIsWorkingAtDesk = consecutiveDeskWindows >= deskEntryWindowCount
        }

        guard nextIsWorkingAtDesk != isWorkingAtDesk else { return }

        isWorkingAtDesk = nextIsWorkingAtDesk
        currentBoutStartedAtS = nextIsWorkingAtDesk ? currentTimeS : nil
        currentDeskBoutSeconds = 0
        DataRecordingManager.shared.recordDeskActivityEvent(
            isWorkingAtDesk: nextIsWorkingAtDesk,
            accumulatedDeskWorkSeconds: accumulatedDeskWorkSeconds,
            currentDeskBoutSeconds: currentDeskBoutSeconds,
            confidence: latestConfidence,
            timestampS: currentTimeS
        )
        print("🪑 Desk activity changed: workingAtDesk=\(nextIsWorkingAtDesk) confidence=\(String(format: "%.2f", latestConfidence)) total=\(Int(accumulatedDeskWorkSeconds))s")
    }

    private func recordSnapshotIfNeeded(currentTimeS: Double) {
        guard currentTimeS - lastSnapshotAtS >= snapshotIntervalSeconds else { return }
        lastSnapshotAtS = currentTimeS

        DataRecordingManager.shared.recordDeskActivityEvent(
            isWorkingAtDesk: isWorkingAtDesk,
            accumulatedDeskWorkSeconds: accumulatedDeskWorkSeconds,
            currentDeskBoutSeconds: currentDeskBoutSeconds,
            confidence: latestConfidence,
            timestampS: currentTimeS
        )
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func range(_ values: [Double]) -> Double {
        guard let min = values.min(), let max = values.max() else { return 0 }
        return max - min
    }

    private func addDeskWorkSeconds(_ seconds: TimeInterval, timestampS: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        accumulatedDeskWorkSeconds += seconds
        UserDefaults.standard.set(accumulatedDeskWorkSeconds, forKey: Self.dailyTotalKey)
        UserDefaults.standard.set(
            Self.dayIdentifier(for: Date(timeIntervalSince1970: timestampS)),
            forKey: Self.dailyTotalDayKey
        )
    }

    private func refreshDailyTotalIfNeeded(timestampS: Double = Date().timeIntervalSince1970) {
        let today = Self.dayIdentifier(for: Date(timeIntervalSince1970: timestampS))
        let storedDay = UserDefaults.standard.string(forKey: Self.dailyTotalDayKey)

        guard storedDay == today else {
            UserDefaults.standard.set(today, forKey: Self.dailyTotalDayKey)
            UserDefaults.standard.set(0.0, forKey: Self.dailyTotalKey)
            accumulatedDeskWorkSeconds = 0
            currentDeskBoutSeconds = 0
            currentBoutStartedAtS = nil
            lastSampleTimestampS = nil
            return
        }

        accumulatedDeskWorkSeconds = UserDefaults.standard.double(forKey: Self.dailyTotalKey)
    }

    private static func dayIdentifier(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    private static let dailyTotalKey = "deskActivityDailyTotalSeconds"
    private static let dailyTotalDayKey = "deskActivityDailyTotalDay"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
