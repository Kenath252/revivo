//
//  WatchSessionManager.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import Foundation
import WatchKit
import WatchConnectivity
import UserNotifications

class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    static let shared = WatchSessionManager()

    @Published var personalisationAccessEnabled = false
    @Published var baselineAccessEnabled = false
    @Published var isActiveBreakRunning = false
    @Published var phoneBreakElapsedSeconds: TimeInterval = 0
    @Published var phoneBreakTimerRunning = false
    @Published private(set) var phoneStatusSentAtS: TimeInterval = 0
    @Published private(set) var phoneStatusReceivedAtS: TimeInterval = 0
    @Published var phoneCurrentDeskBoutSeconds: TimeInterval = 0
    @Published var phoneAccumulatedDeskWorkSeconds: TimeInterval = 0
    @Published var phoneCurrentMode = ""
    @Published var phoneCurrentCommand = ""
    @Published var pendingBaselineBreakId: String?
    @Published var pendingBaselineBreakTitle = "Time to take an active break"
    @Published var pendingBaselineBreakBody = "Do any physical activity you like and revitalise yourself."
    private var lastBackgroundIMUTransferAtS: TimeInterval = 0
    private var respondedBaselineBreakIds: Set<String> = []
    private var pendingBaselineBreakClearWorkItem: DispatchWorkItem?
    private var lastCommandSignature: String?
    private var lastCommandSentAtS: TimeInterval = 0
    private let backgroundIMUTransferIntervalS: TimeInterval = 0.5
    private let duplicateCommandSuppressWindowS: TimeInterval = 1.5

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerBaselineNotificationActions()
        activateSession()
    }
    
    func activateSession() {
        guard WCSession.isSupported() else {
            print("🚫 WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        applyApplicationContext(session.applicationContext)

        guard session.activationState == .notActivated else {
            print("✅ WatchConnectivity session already active state=\(session.activationState.rawValue)")
            return
        }

        session.activate()
        print("✅ WatchConnectivity session activating")
    }
    
    // MARK: - Send App is opened to iPhone
    func notifyPhoneAppOpened() {
        WCSession.default.sendMessage(
            ["event": "watchOpened"],
            replyHandler: { [weak self] reply in
                self?.applyApplicationContext(reply)
            },
            errorHandler: { error in
                print("❌ Could not request phone status:", error.localizedDescription)
            }
        )
    }
    
    // MARK: - Send Message to iPhone
    func sendCommand(_ command: String, mode: Any) {
        // ✅ Safely convert mode to a String
        let modeValue: String
        if let robotMode = mode as? RobotMode {
            modeValue = robotMode.rawValue
        } else if let modeString = mode as? String {
            modeValue = modeString
        } else {
            modeValue = String(describing: mode)
        }

        let now = Date().timeIntervalSince1970
        let signature = "\(command)|\(modeValue)"
        if signature == lastCommandSignature,
           now - lastCommandSentAtS < duplicateCommandSuppressWindowS {
            print("⏭ Suppressed duplicate command:", signature)
            return
        }
        lastCommandSignature = signature
        lastCommandSentAtS = now
        
        let message: [String: Any] = [
            "command": command,
            "mode": modeValue,
            "commandId": UUID().uuidString,
            "sentAtS": now
        ]
        
        print("📤 Sending message to iPhone:", message)

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { error in
                print("❌ Failed to send command message; queueing for background delivery:", error.localizedDescription)
                WCSession.default.transferUserInfo(message)
            }
        } else {
            print("📦 iPhone not reachable; queueing command for background delivery")
            WCSession.default.transferUserInfo(message)
        }
    }
    
    
    // MARK: - Send IMU data separately
    func sendIMUData(_ imuData: [String: Any]) {
        // Ensure all values are supported types
        let safeData = imuData.mapValues { val -> Any in
            if val is String || val is Int || val is Double || val is Bool {
                return val
            } else {
                return String(describing: val)
            }
        }

        let message: [String: Any] = ["imu": safeData]

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { error in
                print("❌ Failed to send IMU data; considering background delivery:", error.localizedDescription)
                self.transferIMUForBackgroundIfNeeded(message)
            }
        } else {
            transferIMUForBackgroundIfNeeded(message)
        }
    }
    
    
    // MARK: - WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ WCSession activation error: \(error.localizedDescription)")
        } else {
            print("✅ WCSession activated with state: \(activationState.rawValue)")
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        print("📡 iPhone reachable: \(session.isReachable)")
        notifyPhoneAppOpened()
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        print("📩 Message received from iPhone:", message)
        if handleEventMessage(message) {
            applyApplicationContext(message)
            return
        }
        applyApplicationContext(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        _ = handleEventMessage(userInfo)
        applyApplicationContext(userInfo)
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
        completionHandler()
    }

    private func handleEventMessage(_ message: [String: Any]) -> Bool {
        guard let event = message["event"] as? String else { return false }

        if event == "seqPromptPresented" {
            WKInterfaceDevice.current().play(.notification)
            let promptId = message["promptId"] as? String ?? "watchSEQPrompt-\(Int(Date().timeIntervalSince1970))"
            let title = message["title"] as? String ?? "SEQ Check-in"
            let body = message["body"] as? String ?? "During the last 30 minutes, how have you felt?"
            presentSEQPromptNotification(title: title, body: body, promptId: promptId)
            return true
        }

        if event == "baselineRevitalisationBreak" {
            let breakId = message["breakId"] as? String ?? "watchBaselineRevitalisationBreak-\(Int(Date().timeIntervalSince1970))"
            let title = message["title"] as? String ?? "Time to take an active break"
            let body = message["body"] as? String ?? "Do any physical activity you like and revitalise yourself."
            presentBaselineBreakNotification(title: title, body: body, breakId: breakId)
            return true
        }

        if event == "activeBreakStarted" {
            DispatchQueue.main.async {
                self.isActiveBreakRunning = true
                self.phoneBreakTimerRunning = true
                if self.phoneBreakElapsedSeconds <= 0 {
                    self.phoneBreakElapsedSeconds = 0
                }
                let now = Date().timeIntervalSince1970
                self.phoneStatusSentAtS = message["phoneStatusSentAtS"] as? Double ?? now
                self.phoneStatusReceivedAtS = now
            }
            return true
        }

        if event == "activeBreakStopped" {
            DispatchQueue.main.async {
                self.isActiveBreakRunning = false
                self.phoneBreakTimerRunning = false
                self.phoneCurrentCommand = "stopBreak"
            }
            return true
        }

        return false
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        applyApplicationContext(applicationContext)
    }
    
    func sendPhysioData(hr: Double?, hrv: Double?) {
        var payload: [String: Any] = [:]

        if let hr = hr { payload["hr"] = hr }
        if let hrv = hrv { payload["hrv"] = hrv }

        payload["timestamp"] = Date().timeIntervalSince1970

        let message = ["physio": payload]

        if WCSession.default.isReachable {
            // 🚀 Real-time (foreground)
            WCSession.default.sendMessage(
                message,
                replyHandler: nil
            ) { error in
                print("❌ sendMessage failed; queueing physio for background delivery:", error.localizedDescription)
                WCSession.default.transferUserInfo(message)
            }
        } else {
            // 📦 Fallback (background delivery)
            WCSession.default.transferUserInfo(message)
        }
    }

    func respondToPendingBaselineBreak(_ response: String) {
        guard let breakId = pendingBaselineBreakId else { return }
        recordBaselineBreakResponse(breakId: breakId, response: response)
    }

    private func transferIMUForBackgroundIfNeeded(_ message: [String: Any]) {
        let now = Date().timeIntervalSince1970
        guard now - lastBackgroundIMUTransferAtS >= backgroundIMUTransferIntervalS else { return }
        lastBackgroundIMUTransferAtS = now
        WCSession.default.transferUserInfo(message)
    }

    private func applyApplicationContext(_ context: [String: Any]) {
        let personalisationEnabled = context["personalisationAccessEnabled"] as? Bool
        let baselineEnabled = context["baselineAccessEnabled"] as? Bool
        let breakElapsedSeconds = context["phoneBreakElapsedSeconds"] as? Double
        let breakTimerRunning = context["phoneBreakTimerRunning"] as? Bool
        let statusSentAtS = context["phoneStatusSentAtS"] as? Double
        let currentDeskBoutSeconds = context["phoneCurrentDeskBoutSeconds"] as? Double
        let accumulatedDeskWorkSeconds = context["phoneAccumulatedDeskWorkSeconds"] as? Double
        let currentMode = context["phoneCurrentMode"] as? String
        let currentCommand = context["phoneCurrentCommand"] as? String
        let hasPhoneStatus =
            breakElapsedSeconds != nil ||
            breakTimerRunning != nil ||
            statusSentAtS != nil ||
            currentDeskBoutSeconds != nil ||
            accumulatedDeskWorkSeconds != nil ||
            currentMode != nil ||
            currentCommand != nil

        guard personalisationEnabled != nil || baselineEnabled != nil || hasPhoneStatus else { return }

        DispatchQueue.main.async {
            if let personalisationEnabled {
                self.personalisationAccessEnabled = personalisationEnabled
            }
            if let baselineEnabled {
                self.baselineAccessEnabled = baselineEnabled
                if baselineEnabled {
                    self.requestBaselineNotificationAuthorizationIfNeeded()
                }
            }
            if let breakElapsedSeconds {
                self.phoneBreakElapsedSeconds = breakElapsedSeconds
            }
            if let breakTimerRunning {
                self.phoneBreakTimerRunning = breakTimerRunning
            }
            if let statusSentAtS {
                self.phoneStatusSentAtS = statusSentAtS
            }
            if let currentDeskBoutSeconds {
                self.phoneCurrentDeskBoutSeconds = currentDeskBoutSeconds
            }
            if let accumulatedDeskWorkSeconds {
                self.phoneAccumulatedDeskWorkSeconds = accumulatedDeskWorkSeconds
            }
            if let currentMode {
                self.phoneCurrentMode = currentMode
            }
            if let currentCommand {
                self.phoneCurrentCommand = currentCommand
            }
            if hasPhoneStatus {
                self.phoneStatusReceivedAtS = Date().timeIntervalSince1970
            }
        }
    }

    private func presentBaselineBreakNotification(title: String, body: String, breakId: String) {
        guard !respondedBaselineBreakIds.contains(breakId) else { return }

        WKInterfaceDevice.current().play(.notification)
        requestBaselineNotificationAuthorizationIfNeeded()
        presentBaselineBreakPrompt(title: title, body: body, breakId: breakId)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.baselineBreakCategoryIdentifier
        content.userInfo = ["breakId": breakId]

        let request = UNNotificationRequest(
            identifier: breakId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("❌ Could not present watch baseline break notification:", error.localizedDescription)
            }
        }
        scheduleBaselineBreakNotificationClear(breakId: breakId)
    }

    private func presentSEQPromptNotification(title: String, body: String, promptId: String) {
        requestBaselineNotificationAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["promptId": promptId]

        let request = UNNotificationRequest(
            identifier: promptId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("❌ Could not present watch SEQ notification:", error.localizedDescription)
            }
        }
    }

    private func presentBaselineBreakPrompt(title: String, body: String, breakId: String) {
        guard !respondedBaselineBreakIds.contains(breakId) else { return }

        DispatchQueue.main.async {
            guard !self.respondedBaselineBreakIds.contains(breakId) else { return }
            self.pendingBaselineBreakClearWorkItem?.cancel()
            self.pendingBaselineBreakId = breakId
            self.pendingBaselineBreakTitle = title
            self.pendingBaselineBreakBody = body

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingBaselineBreakId == breakId,
                      !self.respondedBaselineBreakIds.contains(breakId)
                else { return }

                self.pendingBaselineBreakId = nil
                print("⌛ Watch in-app baseline break prompt cleared after \(Int(Self.baselineBreakResponseTimeoutS))s breakId=\(breakId)")
            }
            self.pendingBaselineBreakClearWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.baselineBreakResponseTimeoutS, execute: workItem)
        }
    }

    private func scheduleBaselineBreakNotificationClear(breakId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.baselineBreakResponseTimeoutS) { [weak self] in
            guard let self else { return }
            guard !self.respondedBaselineBreakIds.contains(breakId) else { return }

            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [breakId])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [breakId])
            print("⌛ Watch baseline break notification cleared after \(Int(Self.baselineBreakResponseTimeoutS))s breakId=\(breakId)")
        }
    }

    private func requestBaselineNotificationAuthorizationIfNeeded() {
        registerBaselineNotificationActions()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { isGranted, error in
            if let error {
                print("❌ Watch baseline notification authorization failed:", error.localizedDescription)
            } else {
                print("🔔 Watch baseline notification authorization granted=\(isGranted)")
            }
        }
    }

    private func registerBaselineNotificationActions() {
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
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
        recordBaselineBreakResponse(breakId: breakId, response: selectedResponse)
    }

    private func recordBaselineBreakResponse(breakId: String, response: String) {
        respondedBaselineBreakIds.insert(breakId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [breakId])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [breakId])

        DispatchQueue.main.async {
            if self.pendingBaselineBreakId == breakId {
                self.pendingBaselineBreakId = nil
            }
            self.pendingBaselineBreakClearWorkItem?.cancel()
            self.pendingBaselineBreakClearWorkItem = nil
        }

        if response == "accepted" {
            DispatchQueue.main.async {
                self.isActiveBreakRunning = true
            }
        }
        sendBaselineBreakResponse(breakId: breakId, response: response)
    }

    private func sendBaselineBreakResponse(breakId: String, response: String) {
        activateSession()

        let message: [String: Any] = [
            "event": "baselineBreakResponse",
            "breakId": breakId,
            "response": response,
            "timestamp": Date().timeIntervalSince1970
        ]

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { error in
                print("❌ Failed to send baseline break response; queueing:", error.localizedDescription)
                WCSession.default.transferUserInfo(message)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }

        do {
            try WCSession.default.updateApplicationContext(message)
        } catch {
            print("❌ Failed to update baseline break response context:", error.localizedDescription)
        }

        print("📝 Watch baseline break \(response) breakId=\(breakId)")
    }

    private static let baselineBreakCategoryIdentifier = "baselineRevitalisationBreakCategory"
    private static let baselineBreakAcceptActionIdentifier = "baselineBreakAcceptAction"
    private static let baselineBreakRejectActionIdentifier = "baselineBreakRejectAction"
    private static let baselineBreakResponseTimeoutS: TimeInterval = 30
}
