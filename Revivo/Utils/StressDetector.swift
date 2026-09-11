//
//  StressDetector.swift
//  Revivo
//
//  Created by Uduwara Perera on 20/11/2025.
//

import Foundation
import UserNotifications
import WatchConnectivity

enum RevitalisationResponseMode {
    case interaction
    case baseline
}

class Detector {
    static let shared = Detector()
    
    private var recentHR: Double = 0
    private var recentHRV: Double = 0
    private var recentHRVTimestampS: Double = 0
    private let heartFeatureProcessor = HeartFeatureProcessor()
    private let heartFeatureQueue = DispatchQueue(label: "Revivo.heartFeatureProcessor", qos: .utility)
    private let hrvFreshnessLimitS = 120.0
    private let detectionCooldownS = 5 * 60.0
    private let acceptedBreakCooldownS = 25 * 60.0
    private let ignoredBreakRetryDelaysS = [8 * 60.0, 15 * 60.0, 25 * 60.0]
    private let prolongedDeskBoutBreakS = 120 * 60.0
    private let lowEnvelopeCutoff = 0.35
    private let highStrainZLimit = 1.0
    private let requiredConsecutiveDetections = 5
    private let interactionMinimumDurationS = 90.0
    private let interactionMaximumDurationS = 5 * 60.0
    private let interactionPreClosureDurationS = 30.0
    private let requiredNegativeHRSlopeWindows = 3

    private var baselineProfile: PersonalBaselineProfile?
    private var baselineParticipantId: String?
    private(set) var latestHeartFeatureWindow: HeartFeatureWindow?
    private var isDetectionEnabled = false
    private var responseMode: RevitalisationResponseMode = .interaction
    private var consecutiveLowActivationDetections = 0
    private var lastRevitalisationNotificationS: TimeInterval = 0
    private var lastAcceptedBreakS: TimeInterval = 0
    private var ignoredBreakCount = 0
    private var ignoredBreakRetryAllowedAtS: TimeInterval = 0
    private var consecutiveNegativeInteractionHRSlopeWindows = 0
    private var hasRequestedInteractionAutoStop = false
    
    private init() {}

    func loadBaselineProfile(participantId: String) {
        baselineParticipantId = participantId
        baselineProfile = DataRecordingManager.shared.loadBaselineProfile(participantId: participantId)
        consecutiveLowActivationDetections = 0

        if let baselineProfile {
            print(
                """
                ✅ Loaded baseline profile for \(baselineProfile.participantId)
                   defaultCompositeThreshold=\(String(format: "%.3f", baselineProfile.defaultCompositeThreshold))
                   calibratedCompositeThreshold=\(String(format: "%.3f", baselineProfile.calibratedCompositeThreshold))
                   lowEnvelopeCutoff=\(String(format: "%.2f", lowEnvelopeCutoff))
                   highStrainZLimit=\(String(format: "%.2f", highStrainZLimit))
                   requiredConsecutiveDetections=\(requiredConsecutiveDetections)
                """
            )
        } else {
            print("⚠️ No baseline profile found for \(participantId)")
        }

        printThresholdOverrideState()
    }

    func setDetectionEnabled(_ isEnabled: Bool) {
        isDetectionEnabled = isEnabled
        if !isEnabled {
            consecutiveLowActivationDetections = 0
            resetInteractionAutoStopTracking()
        }
    }

    func setRevitalisationResponseMode(_ mode: RevitalisationResponseMode) {
        responseMode = mode
    }

    func recordBreakAccepted(source: String) {
        lastAcceptedBreakS = Date().timeIntervalSince1970
        ignoredBreakCount = 0
        ignoredBreakRetryAllowedAtS = 0
        if source == "robotHandHold" {
            resetInteractionAutoStopTracking()
        }
        print("✅ Accepted break recorded by detector source=\(source); next invitation blocked for \(Int(acceptedBreakCooldownS / 60)) min")
    }

    func recordBreakIgnored(source: String) {
        let now = Date().timeIntervalSince1970
        let retryDelayS = ignoredBreakRetryDelay(forIgnoredCount: ignoredBreakCount + 1)
        ignoredBreakCount += 1
        ignoredBreakRetryAllowedAtS = now + retryDelayS
        print("⌛ Ignored break recorded by detector source=\(source); ignoredCount=\(ignoredBreakCount); next retry allowed in \(Int(retryDelayS / 60)) min")
    }

    func updateHR(_ hr: Double, timestampS: Double = Date().timeIntervalSince1970) {
        recentHR = hr
        heartFeatureQueue.async { [weak self] in
            guard let self = self else { return }

            let hrv = self.recentHRVIsFresh(for: timestampS) ? self.recentHRV : nil
            let featureWindows = self.heartFeatureProcessor.append(hr: hr, hrv: hrv, timestampS: timestampS)
            guard !featureWindows.isEmpty else { return }

            DispatchQueue.main.async {
                featureWindows.forEach(self.publish)
            }
        }
    }

    func updateHRV(_ hrv: Double, timestampS: Double = Date().timeIntervalSince1970) {
        guard hrv.isFinite, hrv > 0 else { return }
        recentHRV = hrv
        recentHRVTimestampS = timestampS
    }

    private func evaluateLowActivationLowStrainIfPossible() {
        guard isDetectionEnabled else { return }
        let prolongedDeskBout = DeskActivityManager.shared.currentDeskBoutSeconds >= prolongedDeskBoutBreakS
        if prolongedDeskBout {
            print("🧭 Prolonged desk bout trigger deskBout=\(Int(DeskActivityManager.shared.currentDeskBoutSeconds))s >= \(Int(prolongedDeskBoutBreakS))s")
            postRevitalisationRequiredIfNeeded(
                compositeScore: nil,
                lowEnvelopeCount: nil,
                triggerReason: "prolongedDeskBout"
            )
            return
        }

        guard let baselineProfile else { return }
        guard let heartWindow = latestHeartFeatureWindow else { return }

        let values = featureValues(heartWindow: heartWindow)
        let zScores = orientedZScores(values: values, baselineProfile: baselineProfile)
        guard !zScores.isEmpty else { return }

        let compositeScore = mean(zScores.map(\.value))
        let lowEnvelopeCount = lowEnvelopeFeatureCount(values: values, baselineProfile: baselineProfile)
        let requiredLowEnvelopeCount = max(2, Int(ceil(Double(values.count) * 0.30)))
        let compositeThreshold = effectiveCompositeThreshold(for: baselineProfile)
        let lowComposite = compositeScore <= compositeThreshold
        let lowEnvelope = lowEnvelopeCount >= requiredLowEnvelopeCount
        let lowStrain = passesLowStrainGuard(values: values, baselineProfile: baselineProfile)
        let thresholdOverrideEnabled = Self.isThresholdOverrideEnabled
        let physiologicalGatePassed = thresholdOverrideEnabled
            ? lowComposite
            : (lowComposite && lowEnvelope && lowStrain)

        if physiologicalGatePassed {
            consecutiveLowActivationDetections += 1
        } else {
            consecutiveLowActivationDetections = 0
        }

        print(
            "🧭 Heart-only revitalisation thresholds composite=\(String(format: "%.3f", compositeScore)) <= \(compositeThresholdLabel())=\(String(format: "%.3f", compositeThreshold)) [\(lowComposite)] lowEnvelope=\(lowEnvelopeCount)/\(values.count) >= \(requiredLowEnvelopeCount) [\(lowEnvelope)] lowStrainZLimit=\(String(format: "%.2f", highStrainZLimit)) [\(lowStrain)] overrideMode=\(thresholdOverrideEnabled) physiologicalGate=\(physiologicalGatePassed) consecutive=\(consecutiveLowActivationDetections)/\(requiredConsecutiveDetections) deskBout=\(Int(DeskActivityManager.shared.currentDeskBoutSeconds))s prolongedDeskBout=\(prolongedDeskBout)"
        )

        let physiologicalTrigger = consecutiveLowActivationDetections >= requiredConsecutiveDetections
        guard physiologicalTrigger else { return }

        postRevitalisationRequiredIfNeeded(
            compositeScore: compositeScore,
            lowEnvelopeCount: lowEnvelopeCount,
            triggerReason: "lowActivationLowStrain"
        )
    }

    private func publish(_ features: HeartFeatureWindow) {
        latestHeartFeatureWindow = features
        DataRecordingManager.shared.recordHeartWindow(features)
        evaluateLowActivationLowStrainIfPossible()
        evaluateInteractionAutoStopIfNeeded(features)
        print("❤️ HR features window=\(String(format: "%.1f", features.windowStartS))-\(String(format: "%.1f", features.windowEndS)) hr_mean=\(String(format: "%.2f", features.hrMean)) hrv_mean=\(String(format: "%.2f", features.hrvMean)) sdnn_proxy=\(String(format: "%.2f", features.sdnnProxy)) hr_slope=\(String(format: "%.4f", features.hrSlope))")
    }

    private func evaluateInteractionAutoStopIfNeeded(_ features: HeartFeatureWindow) {
        guard responseMode == .interaction,
              TimerController.shared.timerState.isRunning,
              !hasRequestedInteractionAutoStop
        else {
            if !TimerController.shared.timerState.isRunning {
                consecutiveNegativeInteractionHRSlopeWindows = 0
            }
            return
        }

        let elapsedS = TimerController.shared.timerState.timeElapsed
        guard elapsedS > 0 else { return }

        let maximumPreClosureStartS = interactionMaximumDurationS - interactionPreClosureDurationS
        if elapsedS >= maximumPreClosureStartS {
            requestInteractionAutoStop(
                reason: "maximumCap",
                elapsedS: elapsedS,
                hrSlope: features.hrSlope
            )
            return
        }

        guard elapsedS >= interactionMinimumDurationS else {
            print("⏱ Interaction auto-stop waiting for minimum duration elapsed=\(Int(elapsedS))s/\(Int(interactionMinimumDurationS))s")
            return
        }

        if features.hrSlope.isFinite, features.hrSlope < 0 {
            consecutiveNegativeInteractionHRSlopeWindows += 1
        } else {
            consecutiveNegativeInteractionHRSlopeWindows = 0
        }

        print("📉 Interaction HR recovery check elapsed=\(Int(elapsedS))s hrSlope=\(String(format: "%.4f", features.hrSlope)) negativeWindows=\(consecutiveNegativeInteractionHRSlopeWindows)/\(requiredNegativeHRSlopeWindows)")

        guard consecutiveNegativeInteractionHRSlopeWindows >= requiredNegativeHRSlopeWindows else { return }

        requestInteractionAutoStop(
            reason: "hrPeakPassed",
            elapsedS: elapsedS,
            hrSlope: features.hrSlope
        )
    }

    private func requestInteractionAutoStop(reason: String, elapsedS: TimeInterval, hrSlope: Double) {
        hasRequestedInteractionAutoStop = true
        consecutiveNegativeInteractionHRSlopeWindows = 0
        print("🛑 Interaction pre-closure requested reason=\(reason) elapsed=\(Int(elapsedS))s hrSlope=\(String(format: "%.4f", hrSlope)) duration=\(Int(interactionPreClosureDurationS))s")
        PhoneWCManager.shared.beginInteractionPreClosure(
            source: "auto-\(reason)",
            duration: interactionPreClosureDurationS
        )
    }

    private func resetInteractionAutoStopTracking() {
        consecutiveNegativeInteractionHRSlopeWindows = 0
        hasRequestedInteractionAutoStop = false
    }

    private func featureValues(heartWindow: HeartFeatureWindow) -> [String: Double] {
        [
            "hrMean": heartWindow.hrMean,
            "hrvMean": heartWindow.hrvMean.isFinite ? heartWindow.hrvMean : heartWindow.sdnnProxy,
            "hrSlope": heartWindow.hrSlope
        ].filter { _, value in value.isFinite }
    }

    private func orientedZScores(values: [String: Double], baselineProfile: PersonalBaselineProfile) -> [(name: String, value: Double)] {
        values.compactMap { featureName, value in
            guard let baseline = baselineProfile.features[featureName],
                  baseline.standardDeviation.isFinite,
                  baseline.standardDeviation > 0
            else { return nil }

            let direction = Self.lowActivationDirections[featureName] ?? 1.0
            return (featureName, direction * ((value - baseline.mean) / baseline.standardDeviation))
        }
    }

    private func lowEnvelopeFeatureCount(values: [String: Double], baselineProfile: PersonalBaselineProfile) -> Int {
        values.reduce(0) { count, item in
            let (featureName, value) = item
            guard let baseline = baselineProfile.features[featureName] else { return count }
            let range = baseline.rangeMaximum - baseline.rangeMinimum
            guard range.isFinite, range > 0 else { return count }

            let direction = Self.lowActivationDirections[featureName] ?? 1.0
            let lowActivationPosition = direction >= 0
                ? (value - baseline.rangeMinimum) / range
                : (baseline.rangeMaximum - value) / range

            return lowActivationPosition <= lowEnvelopeCutoff ? count + 1 : count
        }
    }

    private func passesLowStrainGuard(values: [String: Double], baselineProfile: PersonalBaselineProfile) -> Bool {
        for (featureName, direction) in Self.highStrainGuardDirections {
            guard let value = values[featureName],
                  let baseline = baselineProfile.features[featureName],
                  baseline.standardDeviation.isFinite,
                  baseline.standardDeviation > 0
            else { continue }

            let z = (value - baseline.mean) / baseline.standardDeviation
            if direction * z > highStrainZLimit {
                return false
            }
        }

        return true
    }

    private func postRevitalisationRequiredIfNeeded(compositeScore: Double?, lowEnvelopeCount: Int?, triggerReason: String) {
        let now = Date().timeIntervalSince1970
        let acceptedCooldownRemainingS = acceptedBreakCooldownS - (now - lastAcceptedBreakS)
        guard acceptedCooldownRemainingS <= 0 else {
            print("⏳ Revitalisation suppressed: accepted-break quiet period active for \(Int(ceil(acceptedCooldownRemainingS)))s")
            return
        }

        let cooldownRemainingS = detectionCooldownS - (now - lastRevitalisationNotificationS)
        guard cooldownRemainingS <= 0 else {
            print("⏳ Revitalisation suppressed: cooldown active for \(Int(ceil(cooldownRemainingS)))s")
            return
        }
        let ignoredRetryRemainingS = ignoredBreakRetryAllowedAtS - now
        guard ignoredRetryRemainingS <= 0 else {
            print("⏳ Revitalisation suppressed: ignored-break retry delay active for \(Int(ceil(ignoredRetryRemainingS)))s")
            return
        }
        guard DeskActivityManager.shared.isWorkingAtDesk else {
            print("🪑 Revitalisation suppressed: \(triggerReason) detected, but IMU does not indicate desk work")
            return
        }
        guard !CalendarAvailabilityManager.shared.isInMeeting else {
            print("📅 Revitalisation suppressed: \(triggerReason) detected, but Calendar indicates a meeting")
            return
        }

        lastRevitalisationNotificationS = now
        var userInfo: [String: Any] = ["triggerReason": triggerReason]
        if let compositeScore {
            userInfo["compositeScore"] = compositeScore
        }
        if let lowEnvelopeCount {
            userInfo["lowEnvelopeFeatureCount"] = lowEnvelopeCount
        }

        NotificationCenter.default.post(
            name: .revitalisationRequired,
            object: nil,
            userInfo: userInfo
        )
        NotificationCenter.default.post(name: .stressDetected, object: nil)
        switch responseMode {
        case .interaction:
            RobotController.shared.nudgeForRevitalisation()
            print("⚡ Revitalisation required: \(triggerReason) detected; robot nudge sent")
        case .baseline:
            postBaselineBreakNotification()
            print("⚡ Revitalisation required: \(triggerReason) detected; baseline phone notification sent")
        }
    }

    private func ignoredBreakRetryDelay(forIgnoredCount ignoredCount: Int) -> TimeInterval {
        let index = min(max(ignoredCount - 1, 0), ignoredBreakRetryDelaysS.count - 1)
        return ignoredBreakRetryDelaysS[index]
    }

    private func postBaselineBreakNotification() {
        let title = "Time to take an active break"
        let body = "Do any physical activity you like and revitalise yourself."
        let breakId = "baselineRevitalisationBreak-\(Int(Date().timeIntervalSince1970))"
        PhoneWCManager.shared.prepareBaselineBreakNotifications()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = PhoneWCManager.baselineBreakCategoryIdentifier
        content.userInfo = ["breakId": breakId]

        let request = UNNotificationRequest(
            identifier: breakId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("❌ Could not present baseline break notification:", error.localizedDescription)
            }
        }
        DataRecordingManager.shared.recordBaselineBreakNotification(
            breakId: breakId,
            title: title,
            body: body,
            deliveredToPhone: true,
            deliveredToWatch: WCSession.isSupported(),
            timeoutSeconds: PhoneWCManager.baselineBreakResponseTimeoutS
        )
        PhoneWCManager.shared.scheduleBaselineBreakNotificationClear(breakId: breakId)
        PhoneWCManager.shared.notifyBaselineBreak(title: title, body: body, breakId: breakId)
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private func recentHRVIsFresh(for timestampS: Double) -> Bool {
        recentHRV.isFinite &&
        recentHRV > 0 &&
        recentHRVTimestampS > 0 &&
        abs(timestampS - recentHRVTimestampS) <= hrvFreshnessLimitS
    }

    private func effectiveCompositeThreshold(for baselineProfile: PersonalBaselineProfile) -> Double {
        guard Self.isThresholdOverrideEnabled else {
            return baselineProfile.calibratedCompositeThreshold
        }

        guard let overrideValue = UserDefaults.standard.object(forKey: Self.thresholdOverrideValueKey) as? Double else {
            return baselineProfile.calibratedCompositeThreshold
        }
        return overrideValue.isFinite ? overrideValue : baselineProfile.calibratedCompositeThreshold
    }

    private func compositeThresholdLabel() -> String {
        Self.isThresholdOverrideEnabled
            ? "overrideThreshold"
            : "calibratedThreshold"
    }

    private func printThresholdOverrideState() {
        let isEnabled = Self.isThresholdOverrideEnabled
        let overrideValue = UserDefaults.standard.object(forKey: Self.thresholdOverrideValueKey) as? Double
        let valueText = overrideValue.map { String(format: "%.3f", $0) } ?? "unset"
        print("🧪 Threshold override enabled=\(isEnabled) value=\(valueText)")
    }

    private static let lowActivationDirections: [String: Double] = [
        "hrMean": 1,
        "hrvMean": -1,
        "hrSlope": 1
    ]

    private static let highStrainGuardDirections: [String: Double] = [
        "hrMean": 1,
        "hrvMean": -1,
        "hrSlope": 1
    ]

    private static let thresholdOverrideEnabledKey = "detectorThresholdOverrideEnabled"
    private static let thresholdOverrideValueKey = "detectorThresholdOverrideValue"

    private static var isThresholdOverrideEnabled: Bool {
        UserDefaults.standard.bool(forKey: thresholdOverrideEnabledKey)
    }
}

extension Notification.Name {
    static let revitalisationRequired = Notification.Name("revitalisationRequired")
    static let interactionInvitationWaiting = Notification.Name("interactionInvitationWaiting")
    static let interactionAccepted = Notification.Name("interactionAccepted")
    static let interactionRejected = Notification.Name("interactionRejected")
    static let stressDetected = Notification.Name("stressDetected")
    static let baselineBreakResponseRecorded = Notification.Name("baselineBreakResponseRecorded")
    static let activeBreakStopped = Notification.Name("activeBreakStopped")
    static let activeBreakCompleted = Notification.Name("activeBreakCompleted")
    static let activeBreakQuestionnaireSubmitted = Notification.Name("activeBreakQuestionnaireSubmitted")
    static let seqPromptNotificationTapped = Notification.Name("seqPromptNotificationTapped")
}
