//
//  PhoneWCManager.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import WatchConnectivity
import Combine
import UserNotifications

class PhoneWCManager: NSObject, ObservableObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    static let shared = PhoneWCManager()
    
    @Published var currentMode: String? = nil
    @Published var currentCommand: String? = nil
    private var acceptedBaselineBreakIds: Set<String> = []
    private var respondedBaselineBreakIds: Set<String> = []
    private var watchStatusCancellable: AnyCancellable?
    private var interactionAcceptedCancellable: AnyCancellable?
    private var preClosureFallbackWorkItem: DispatchWorkItem?
    private var processedCommandIds: [String: TimeInterval] = [:]
    private var lastCommandSignature: String?
    private var lastCommandHandledAtS: TimeInterval = 0
    private let duplicateCommandSuppressWindowS: TimeInterval = 2.0
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerBaselineNotificationActions()
        registerSEQNotificationCategory()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            print("✅ iPhone WCSession activated")
        }
        startWatchStatusSync()
        observeInteractionAcceptedForWatch()
    }

    func updateWatchModeAccess(personalisationEnabled: Bool, baselineEnabled: Bool) {
        guard WCSession.isSupported() else { return }

        var context = currentWatchStatusContext()
        context.merge([
            "personalisationAccessEnabled": personalisationEnabled,
            "baselineAccessEnabled": baselineEnabled
        ]) { _, new in new }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            print("❌ Could not update watch mode access:", error.localizedDescription)
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(context, replyHandler: nil) { error in
                print("❌ Could not send watch mode access:", error.localizedDescription)
            }
        }
    }

    private func startWatchStatusSync() {
        watchStatusCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.sendWatchStatus()
            }
    }

    private func sendWatchStatus() {
        guard WCSession.isSupported() else { return }
        let context = currentWatchStatusContext()

        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            print("❌ Could not update watch timer status:", error.localizedDescription)
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(context, replyHandler: nil) { error in
                print("❌ Could not send watch timer status:", error.localizedDescription)
            }
        }
    }

    private func currentWatchStatusContext() -> [String: Any] {
        [
            "personalisationAccessEnabled": Self.personalisationAccessEnabled,
            "baselineAccessEnabled": Self.baselineAccessEnabled,
            "phoneCurrentMode": currentMode ?? "",
            "phoneCurrentCommand": currentCommand ?? "",
            "phoneStatusSentAtS": Date().timeIntervalSince1970,
            "phoneBreakElapsedSeconds": TimerController.shared.timerState.timeElapsed,
            "phoneBreakTimerRunning": TimerController.shared.timerState.isRunning,
            "phoneCurrentDeskBoutSeconds": DeskActivityManager.shared.displayCurrentDeskBoutSeconds,
            "phoneAccumulatedDeskWorkSeconds": DeskActivityManager.shared.accumulatedDeskWorkSeconds
        ]
    }

    func updatePersonalisationAccess(_ isEnabled: Bool) {
        updateWatchModeAccess(personalisationEnabled: isEnabled, baselineEnabled: Self.baselineAccessEnabled)
    }

    private func observeInteractionAcceptedForWatch() {
        interactionAcceptedCancellable = NotificationCenter.default
            .publisher(for: .interactionAccepted)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.notifyWatchActiveBreakStarted()
                    self?.sendWatchStatus()
                }
            }
    }

    func notifySEQPromptPresented(title: String, body: String, promptId: String) {
        guard WCSession.isSupported() else { return }

        let message: [String: Any] = [
            "event": "seqPromptPresented",
            "promptId": promptId,
            "title": title,
            "body": body
        ]

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { error in
                print("❌ Could not notify watch about SEQ prompt:", error.localizedDescription)
                WCSession.default.transferUserInfo(message)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    func scheduleSEQPromptNotification(title: String, body: String, promptId: String, after delay: TimeInterval) {
        prepareSEQPromptNotifications()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.seqPromptCategoryIdentifier
        content.userInfo = ["promptId": promptId]

        let request = UNNotificationRequest(
            identifier: promptId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        )

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [promptId])
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("❌ Could not schedule SEQ notification:", error.localizedDescription)
            }
        }
    }

    func cancelSEQPromptNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.seqPromptNotificationIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.seqPromptNotificationIdentifier])
    }

    func notifyBaselineBreak(title: String, body: String, breakId: String) {
        guard WCSession.isSupported() else { return }

        let message: [String: Any] = [
            "event": "baselineRevitalisationBreak",
            "breakId": breakId,
            "title": title,
            "body": body
        ]

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { error in
                print("❌ Could not notify watch about baseline break:", error.localizedDescription)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    func scheduleBaselineBreakNotificationClear(breakId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.baselineBreakResponseTimeoutS) { [weak self] in
            guard let self else { return }
            guard !self.respondedBaselineBreakIds.contains(breakId) else { return }

            self.respondedBaselineBreakIds.insert(breakId)
            DataRecordingManager.shared.recordBaselineBreakResponse(
                breakId: breakId,
                response: "timedOut",
                source: "system"
            )
            Detector.shared.recordBreakIgnored(source: "baseline-system")
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [breakId])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [breakId])
            print("⌛ Baseline break notification cleared after \(Int(Self.baselineBreakResponseTimeoutS))s breakId=\(breakId)")
        }
    }

    func prepareBaselineBreakNotifications() {
        UNUserNotificationCenter.current().delegate = self
        registerBaselineNotificationActions()
    }

    func prepareSEQPromptNotifications() {
        UNUserNotificationCenter.current().delegate = self
        registerSEQNotificationCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { isGranted, error in
            if let error {
                print("❌ SEQ notification authorization failed:", error.localizedDescription)
            } else {
                print("🔔 SEQ notification authorization granted=\(isGranted)")
            }
        }
    }

    func stopActiveBreak(source: String = "phone") {
        let mode = currentMode ?? RobotMode.baseline.rawValue
        stopActiveBreak(mode: mode, source: source)
    }

    func beginInteractionPreClosure(source: String, duration: TimeInterval) {
        guard currentMode != RobotMode.baseline.rawValue else {
            stopActiveBreak(source: source)
            return
        }

        preClosureFallbackWorkItem?.cancel()
        currentCommand = "preClosure"
        sendWatchStatus()

        let fallback = DispatchWorkItem { [weak self] in
            self?.finishInteractionPreClosure(source: "\(source)-fallback")
        }
        preClosureFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 2.0, execute: fallback)

        RobotController.shared.beginPreClosure(duration: duration) { [weak self] in
            self?.finishInteractionPreClosure(source: source)
        }
    }

    private func finishInteractionPreClosure(source: String) {
        guard currentCommand == "preClosure",
              TimerController.shared.timerState.isRunning
        else { return }

        preClosureFallbackWorkItem?.cancel()
        preClosureFallbackWorkItem = nil
        stopActiveBreak(source: source)
    }
    
    // MARK: - Incoming message from Watch
    /*func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let command = message["command"] as? String,
              let mode = message["mode"] as? String else { return }
        
        DispatchQueue.main.async {
            self.currentMode = mode
            self.currentCommand = command
            print("📩 Received: \(command) for mode: \(mode)")
            
            switch command {
            case "start":
                TimerController.shared.startPauseTimer()
                RobotController.shared.startFSM()
            case "pause":
                TimerController.shared.startPauseTimer()
                RobotController.shared.stopFSM()
            case "stop":
                TimerController.shared.stopTimer()
                RobotController.shared.stopFSM()
            default: break
            }
        }
    }*/
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            
            if let event = message["event"] as? String, event == "watchOpened" {
                    print("📲 Watch app opened → starting HR & HRV monitoring")
                    HRMonitoringController.shared.startMonitoring()   // ← START HR + HRV HERE
                    self.updateWatchModeAccess(
                        personalisationEnabled: Self.personalisationAccessEnabled,
                        baselineEnabled: Self.baselineAccessEnabled
                    )
                    return
                }

            if let event = message["event"] as? String, event == "baselineBreakResponse" {
                self.handleBaselineBreakResponse(message, source: "watch")
                return
            }
            
            // Handle commands
            if let command = message["command"] as? String,
               let mode = message["mode"] as? String {
                guard self.shouldHandleCommand(command, mode: mode, message: message) else { return }
                self.currentMode = mode
                self.currentCommand = command
                let commandId = message["commandId"] as? String ?? "nil"
                let sentAtS = message["sentAtS"] as? Double
                let latencyMs = sentAtS.map { Int((Date().timeIntervalSince1970 - $0) * 1000) }
                print("📩 [\(Self.logTimestamp())] Watch command received id=\(commandId) command=\(command) mode=\(mode) latencyMs=\(latencyMs.map(String.init) ?? "nil")")
                self.handleWatchCommand(command, mode: mode)
            }
            
            // MARK: - Receive live HR + HRV streamed from Watch
            if let physio = message["physio"] as? [String: Any] {
                let hr = physio["hr"] as? Double
                let hrv = physio["hrv"] as? Double
                let timestampS = physio["timestamp"] as? Double ?? Date().timeIntervalSince1970

                if let hr = hr {
                    print("❤️ HR received:", hr)
                    Detector.shared.updateHR(hr, timestampS: timestampS)
                }

                if let hrv = hrv {
                    print("💙 HRV received:", hrv)
                    Detector.shared.updateHRV(hrv, timestampS: timestampS)
                }

                return
            }
            
            
            // Handle IMU data
            /*if let imuData = message["imu"] as? [String: Double] {
                // Now you have roll, pitch, yaw, rotation rates, accelerations, etc.
                // Example:
                let roll = imuData["attitude_roll"] ?? 0
                let pitch = imuData["attitude_pitch"] ?? 0
                let yaw = imuData["attitude_yaw"] ?? 0
                
                // You can now process or store it
                print("📊 Received IMU data: roll=\(roll), pitch=\(pitch), yaw=\(yaw)")
            }*/
            
            if let imuData = message["imu"] as? [String: Double] {
                self.handleIMUData(imuData)
            }
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        DispatchQueue.main.async {
            if let event = message["event"] as? String, event == "watchOpened" {
                print("📲 Watch app opened → replying with current mode access")
                HRMonitoringController.shared.startMonitoring()
                let context = self.currentWatchStatusContext()
                self.updateWatchModeAccess(
                    personalisationEnabled: Self.personalisationAccessEnabled,
                    baselineEnabled: Self.baselineAccessEnabled
                )
                replyHandler(context)
                return
            }

            replyHandler(self.currentWatchStatusContext())
            self.session(session, didReceiveMessage: message)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleBaselineNotificationResponse(response)
        handleSEQNotificationResponse(response)
        completionHandler()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        DispatchQueue.main.async {
            if let event = userInfo["event"] as? String, event == "baselineBreakResponse" {
                self.handleBaselineBreakResponse(userInfo, source: "watch")
                return
            }

            if let command = userInfo["command"] as? String,
               let mode = userInfo["mode"] as? String {
                guard self.shouldHandleCommand(command, mode: mode, message: userInfo) else { return }
                self.currentMode = mode
                self.currentCommand = command
                print("📨 Background command received: \(command) for mode: \(mode)")
                self.handleWatchCommand(command, mode: mode)
            }

            let physio = userInfo["physio"] as? [String: Any] ?? userInfo
            let timestampS = physio["timestamp"] as? Double ?? Date().timeIntervalSince1970

            if let hr = physio["hr"] as? Double {
                print("📨 Background HR received:", hr)
                Detector.shared.updateHR(hr, timestampS: timestampS)
            }

            if let hrv = physio["hrv"] as? Double {
                print("📨 Background HRV received:", hrv)
                Detector.shared.updateHRV(hrv, timestampS: timestampS)
            }

            if let imuData = userInfo["imu"] as? [String: Double] {
                print("📨 Background IMU received")
                self.handleIMUData(imuData)
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            if let event = applicationContext["event"] as? String,
               event == "baselineBreakResponse" {
                self.handleBaselineBreakResponse(applicationContext, source: "watch")
            }
        }
    }
    
    // MARK: - Required WCSessionDelegate methods
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ WCSession activation error: \(error.localizedDescription)")
        } else {
            print("✅ WCSession activated with state: \(activationState.rawValue)")
        }
    }

    private static var participantId: String {
        UserDefaults.standard.string(forKey: "userName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
            .nilIfEmpty ?? "participant"
    }

    private static var personalisationAccessEnabled: Bool {
        UserDefaults.standard.bool(forKey: "personalisationAccessEnabled")
    }

    private static var baselineAccessEnabled: Bool {
        UserDefaults.standard.bool(forKey: "baselineAccessEnabled")
    }

    private static var shouldStartPersonalisationFresh: Bool {
        UserDefaults.standard.bool(forKey: "startPersonalisationFresh")
    }

    static let baselineBreakCategoryIdentifier = "baselineRevitalisationBreakCategory"
    static let baselineBreakAcceptActionIdentifier = "baselineBreakAcceptAction"
    static let baselineBreakRejectActionIdentifier = "baselineBreakRejectAction"
    static let baselineBreakResponseTimeoutS: TimeInterval = 30
    static let seqPromptNotificationIdentifier = "seqQuestionnairePrompt"
    private static let seqPromptCategoryIdentifier = "seqQuestionnairePromptCategory"

    private func requestBaselineNotificationAuthorizationIfNeeded() {
        registerBaselineNotificationActions()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { isGranted, error in
            if let error {
                print("❌ Baseline notification authorization failed:", error.localizedDescription)
            } else {
                print("🔔 Baseline notification authorization granted=\(isGranted)")
            }
        }
    }

    private func registerBaselineNotificationActions() {
        registerNotificationCategories()
    }

    private func registerSEQNotificationCategory() {
        registerNotificationCategories()
    }

    private func registerNotificationCategories() {
        let acceptAction = UNNotificationAction(
            identifier: Self.baselineBreakAcceptActionIdentifier,
            title: "Accept",
            options: []
        )
        let rejectAction = UNNotificationAction(
            identifier: Self.baselineBreakRejectActionIdentifier,
            title: "Reject",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.baselineBreakCategoryIdentifier,
            actions: [acceptAction, rejectAction],
            intentIdentifiers: [],
            options: []
        )
        let seqCategory = UNNotificationCategory(
            identifier: Self.seqPromptCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, seqCategory])
    }

    private func handleBaselineNotificationResponse(_ response: UNNotificationResponse) {
        guard response.notification.request.content.categoryIdentifier == Self.baselineBreakCategoryIdentifier else {
            return
        }

        let selectedResponse: String
        switch response.actionIdentifier {
        case Self.baselineBreakAcceptActionIdentifier:
            selectedResponse = "accepted"
        case Self.baselineBreakRejectActionIdentifier:
            selectedResponse = "rejected"
        default:
            return
        }

        let breakId = response.notification.request.content.userInfo["breakId"] as? String
            ?? response.notification.request.identifier
        recordBaselineBreakResponse(
            breakId: breakId,
            response: selectedResponse,
            source: "phone"
        )
    }

    private func handleSEQNotificationResponse(_ response: UNNotificationResponse) {
        guard response.notification.request.content.categoryIdentifier == Self.seqPromptCategoryIdentifier else {
            return
        }

        let promptId = response.notification.request.content.userInfo["promptId"] as? String
            ?? response.notification.request.identifier
        NotificationCenter.default.post(
            name: .seqPromptNotificationTapped,
            object: nil,
            userInfo: ["promptId": promptId]
        )
    }

    private func handleBaselineBreakResponse(_ message: [String: Any], source: String) {
        guard let response = message["response"] as? String else { return }
        let breakId = message["breakId"] as? String ?? "unknown"
        recordBaselineBreakResponse(breakId: breakId, response: response, source: source)
    }

    private func recordBaselineBreakResponse(breakId: String, response: String, source: String) {
        guard !respondedBaselineBreakIds.contains(breakId) else {
            print("↩️ Ignored duplicate baseline break response breakId=\(breakId) response=\(response) source=\(source)")
            return
        }

        respondedBaselineBreakIds.insert(breakId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [breakId])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [breakId])

        DataRecordingManager.shared.recordBaselineBreakResponse(
            breakId: breakId,
            response: response,
            source: source
        )

        if response == "accepted", !acceptedBaselineBreakIds.contains(breakId) {
            acceptedBaselineBreakIds.insert(breakId)
            Detector.shared.recordBreakAccepted(source: "baseline-\(source)")
            TimerController.shared.startTimer(reset: true)
            DeskActivityManager.shared.pauseCurrentBout(
                reason: "baselineBreakAccepted",
                source: source
            )
            notifyWatchActiveBreakStarted()
            sendWatchStatus()
        } else if response == "rejected" {
            Detector.shared.recordBreakIgnored(source: "baseline-\(source)")
        }

        NotificationCenter.default.post(
            name: .baselineBreakResponseRecorded,
            object: nil,
            userInfo: [
                "breakId": breakId,
                "response": response,
                "source": source
            ]
        )
        print("📝 Baseline break \(response) from \(source) breakId=\(breakId)")
    }

    private func handleWatchCommand(_ command: String, mode: String) {
        let startedAt = Date()
        print("🧭 [\(Self.logTimestamp())] Handling Watch command start command=\(command) mode=\(mode)")
        defer {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("🧭 [\(Self.logTimestamp())] Handling Watch command done command=\(command) mode=\(mode) elapsedMs=\(elapsedMs)")
        }

        switch command {
        case "selectInteraction":
            TimerController.shared.stopTimer()
            Detector.shared.setRevitalisationResponseMode(.interaction)
            RobotController.shared.prepareForInteraction()
            DeskActivityManager.shared.setTrackingEnabled(true)
            DeskActivityManager.shared.resumeCurrentBout(reason: "selectInteraction", source: "watch")
            Detector.shared.loadBaselineProfile(participantId: Self.participantId)
            Detector.shared.setDetectionEnabled(true)
            DataRecordingManager.shared.start(mode: .interaction, participantId: Self.participantId)
            CalendarAvailabilityManager.shared.startMonitoring()
            sendWatchStatus()
        case "selectBaseline":
            TimerController.shared.stopTimer()
            requestBaselineNotificationAuthorizationIfNeeded()
            Detector.shared.setRevitalisationResponseMode(.baseline)
            RobotController.shared.cancelRobotActivityWithoutCommand()
            DeskActivityManager.shared.setTrackingEnabled(true)
            DeskActivityManager.shared.resumeCurrentBout(reason: "selectBaseline", source: "watch")
            Detector.shared.loadBaselineProfile(participantId: Self.participantId)
            Detector.shared.setDetectionEnabled(true)
            DataRecordingManager.shared.start(mode: .baseline, participantId: Self.participantId)
            CalendarAvailabilityManager.shared.startMonitoring()
            sendWatchStatus()
        case "selectPersonalisation":
            DeskActivityManager.shared.setTrackingEnabled(false)
            CalendarAvailabilityManager.shared.stopMonitoring()
            Detector.shared.setDetectionEnabled(false)
        case "startPersonalisation":
            DeskActivityManager.shared.setTrackingEnabled(false)
            CalendarAvailabilityManager.shared.stopMonitoring()
            Detector.shared.setDetectionEnabled(false)
            if Self.shouldStartPersonalisationFresh {
                BaselineCalibrationManager.shared.markFreshPersonalisationStart(participantId: Self.participantId)
                UserDefaults.standard.set(false, forKey: "startPersonalisationFresh")
            }
            DataRecordingManager.shared.start(mode: .personalisation, participantId: Self.participantId)
        case "pausePersonalisation":
            DataRecordingManager.shared.stop()
        case "stopPersonalisation":
            DataRecordingManager.shared.stop(buildBaseline: true, participantIdForBaseline: Self.participantId)
        case "start":
            DeskActivityManager.shared.setTrackingEnabled(true)
            DeskActivityManager.shared.resumeCurrentBout(reason: "watchStart", source: "watch")
            CalendarAvailabilityManager.shared.startMonitoring()
            Detector.shared.loadBaselineProfile(participantId: Self.participantId)
            Detector.shared.setDetectionEnabled(true)
            if mode == RobotMode.baseline.rawValue {
                requestBaselineNotificationAuthorizationIfNeeded()
                Detector.shared.setRevitalisationResponseMode(.baseline)
                RobotController.shared.cancelRobotActivityWithoutCommand()
                DataRecordingManager.shared.start(mode: .baseline, participantId: Self.participantId)
            } else {
                Detector.shared.setRevitalisationResponseMode(.interaction)
                RobotController.shared.prepareForInteraction()
                DataRecordingManager.shared.start(mode: .interaction, participantId: Self.participantId)
            }
            sendWatchStatus()
        case "pause":
            let wasInteractionTimerRunning = TimerController.shared.timerState.isRunning
            DeskActivityManager.shared.pauseCurrentBout(reason: "watchPause", source: "watch")
            DeskActivityManager.shared.setTrackingEnabled(false)
            CalendarAvailabilityManager.shared.stopMonitoring()
            Detector.shared.setDetectionEnabled(false)
            TimerController.shared.pauseTimer()
            DataRecordingManager.shared.stop()
            if mode != RobotMode.baseline.rawValue {
                if wasInteractionTimerRunning {
                    RobotController.shared.stopFSM()
                } else {
                    RobotController.shared.cancelRobotActivityWithoutCommand()
                }
            }
            sendWatchStatus()
        case "stopBreak":
            stopActiveBreak(mode: mode, source: "watch")
        case "stop":
            let wasInteractionTimerRunning = TimerController.shared.timerState.isRunning
            postActiveBreakCompletedIfNeeded(mode: mode, source: "watch")
            DeskActivityManager.shared.resetCurrentBout(reason: "watchStop", source: "watch")
            DeskActivityManager.shared.setTrackingEnabled(false)
            CalendarAvailabilityManager.shared.stopMonitoring()
            Detector.shared.setDetectionEnabled(false)
            DataRecordingManager.shared.stop(
                buildBaseline: currentMode == RobotMode.personalisation.rawValue,
                writeDailySummary: true,
                summarySource: "watchStop"
            )
            TimerController.shared.stopTimer()
            if mode != RobotMode.baseline.rawValue {
                if wasInteractionTimerRunning {
                    RobotController.shared.stopFSM()
                } else {
                    RobotController.shared.cancelRobotActivityWithoutCommand()
                }
            }
            sendWatchStatus()
        default:
            print("⚠️ [\(Self.logTimestamp())] Unhandled Watch command command=\(command) mode=\(mode)")
            break
        }
    }

    private func shouldHandleCommand(_ command: String, mode: String, message: [String: Any]) -> Bool {
        let now = Date().timeIntervalSince1970
        pruneProcessedCommandIds(now: now)

        if let commandId = message["commandId"] as? String, !commandId.isEmpty {
            if processedCommandIds[commandId] != nil {
                print("⏭ Ignored duplicate Watch command id=\(commandId) command=\(command) mode=\(mode)")
                return false
            }
            processedCommandIds[commandId] = now
        }

        let signature = "\(command)|\(mode)"
        if signature == lastCommandSignature,
           now - lastCommandHandledAtS < duplicateCommandSuppressWindowS {
            print("⏭ Ignored rapid duplicate Watch command command=\(command) mode=\(mode)")
            return false
        }

        lastCommandSignature = signature
        lastCommandHandledAtS = now
        return true
    }

    private func pruneProcessedCommandIds(now: TimeInterval) {
        processedCommandIds = processedCommandIds.filter { now - $0.value < 10 * 60 }
    }

    private func stopActiveBreak(mode: String, source: String) {
        let breakDurationSeconds = TimerController.shared.timerState.timeElapsed
        preClosureFallbackWorkItem?.cancel()
        preClosureFallbackWorkItem = nil
        currentMode = mode
        currentCommand = "stopBreak"
        postActiveBreakCompletedIfNeeded(
            mode: mode,
            source: source,
            breakDurationSeconds: breakDurationSeconds
        )
        TimerController.shared.stopTimer()
        DeskActivityManager.shared.resetCurrentBout(reason: "activeBreakStopped", source: source)
        DeskActivityManager.shared.setTrackingEnabled(true)
        CalendarAvailabilityManager.shared.startMonitoring()
        Detector.shared.setDetectionEnabled(true)

        if mode == RobotMode.baseline.rawValue {
            Detector.shared.setRevitalisationResponseMode(.baseline)
            RobotController.shared.cancelRobotActivityWithoutCommand()
        } else {
            Detector.shared.setRevitalisationResponseMode(.interaction)
            RobotController.shared.stopFSM()
        }

        notifyWatchActiveBreakStopped()
        sendWatchStatus()
        NotificationCenter.default.post(
            name: .activeBreakStopped,
            object: nil,
            userInfo: [
                "mode": mode,
                "source": source,
                "breakDurationSeconds": breakDurationSeconds
            ]
        )
        print("🛑 Active break stopped mode=\(mode) source=\(source)")
    }

    private func postActiveBreakCompletedIfNeeded(
        mode: String,
        source: String,
        breakDurationSeconds: TimeInterval? = nil
    ) {
        let breakDurationSeconds = breakDurationSeconds ?? TimerController.shared.timerState.timeElapsed
        guard breakDurationSeconds > 0 else { return }

        NotificationCenter.default.post(
            name: .activeBreakCompleted,
            object: nil,
            userInfo: [
                "mode": mode,
                "source": source,
                "breakDurationSeconds": breakDurationSeconds,
                "completedAtS": Date().timeIntervalSince1970
            ]
        )
        print("📝 Active break completed mode=\(mode) source=\(source) duration=\(Int(breakDurationSeconds))s")
    }

    private func notifyWatchActiveBreakStopped() {
        guard WCSession.isSupported() else { return }
        notifyWatchEvent("activeBreakStopped")
    }

    private func notifyWatchActiveBreakStarted() {
        guard WCSession.isSupported() else { return }
        notifyWatchEvent("activeBreakStarted")
    }

    private func notifyWatchEvent(_ event: String) {
        var message = currentWatchStatusContext()
        message["event"] = event

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { error in
                print("❌ Could not notify watch \(event):", error.localizedDescription)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    private func handleIMUData(_ imuData: [String: Double]) {
        let imu = IMUData(
            timestampS: imuData["timestamp"] ?? Date().timeIntervalSince1970,
            roll: imuData["attitude_roll"] ?? 0,
            pitch: imuData["attitude_pitch"] ?? 0,
            yaw: imuData["attitude_yaw"] ?? 0,
            ax: imuData["user_accel_x"] ?? imuData["ax"] ?? 0,
            ay: imuData["user_accel_y"] ?? imuData["ay"] ?? 0,
            az: imuData["user_accel_z"] ?? imuData["az"] ?? 0
        )
        print("📊 Received IMU data: roll=\(imu.roll), pitch=\(imu.pitch), yaw=\(imu.yaw)")

        DeskActivityManager.shared.ingest(imu)
        if currentMode != RobotMode.baseline.rawValue {
            RobotController.shared.receiveIMU(imu)
        }
    }

    private static func logTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
