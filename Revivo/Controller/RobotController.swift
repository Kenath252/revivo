//
//  RobotController.swift
//  Revivo Watch App
//
//  Created by Uduwara Perera on 7/11/2025.
//


import Foundation
import SwiftUI

class RobotController: ObservableObject {
    static let shared = RobotController()   // ✅ Add this line

    @Published var currentState: RobotCommand.State = .prePunch
    @Published var objectDetected: Bool = false
    @Published var latestIMU: IMUData? = nil
    @Published var userAction: UserAction = .none

    private let robotIP = "192.168.4.1"
    private var espConnection: ESP32Connection?
    private var fsmActive = false
    private var fsmRunID = UUID()
    private var lastIMU: IMUData? = nil
    private var lastActionTime: Date = Date()
    private let minInterval: TimeInterval = 0.25 // 250ms debounce
    private var imuBuffer: [IMUData] = []
    private let bufferSize = 5
    private let windowSize = 25
    private var isNudging = false
    private var isAwaitingInteractionAcceptance = false
    private var handPresenceStartedAt: Date?
    private var lastHandDetectedAt: Date?
    private var acceptanceWindowStartedAt: Date?
    private var acceptanceToFUpdateCount = 0
    private var acceptanceTrueCount = 0
    private var acceptanceFalseCount = 0
    private var currentInteractionInvitationId: String?
    private let handAcceptanceHoldSeconds: TimeInterval = 2.0
    private let handAcceptanceDropoutGraceSeconds: TimeInterval = 0.45
    private let interactionAcceptanceWindowSeconds: TimeInterval = 30.0
    private var robotCommandSequence = 0
    private var scheduledFSMRunID: UUID?
    private var preClosureStartedAt: Date?
    private var preClosureDuration: TimeInterval = 0

    private init() { }  // ✅ Prevent external initialization

    func setup() {
        if espConnection == nil {
            logRobot("setup start robotHTTP=http://\(robotIP) tofTCP=192.168.4.2:5000")
            espConnection = ESP32Connection(ip: "192.168.4.2", port: 5000)
            espConnection?.onObjectUpdate = { [weak self] detected in
                self?.handleObjectDetection(detected)
            }
            espConnection?.connect()
            sendCommand(for: .guardPose)
        } else {
            logRobot("setup skipped existing ESP32Connection")
        }
    }

    func prepareForInteraction() {
        setup()
        fsmActive = false
        fsmRunID = UUID()
        scheduledFSMRunID = nil
        clearPreClosureState()
        isAwaitingInteractionAcceptance = false
        currentInteractionInvitationId = nil
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        holdGuardPose()
        logRobot("prepared in Guard Pose fsmActive=\(fsmActive) runID=\(shortRunID(fsmRunID))")
    }
    
    func startFSM() {
        setup()
        guard !fsmActive else {
            logRobot("FSM start ignored: already active runID=\(shortRunID(fsmRunID))")
            return
        }

        fsmRunID = UUID()
        let runID = fsmRunID
        scheduledFSMRunID = nil
        clearPreClosureState()
        isAwaitingInteractionAcceptance = false
        currentInteractionInvitationId = nil
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        fsmActive = true
        logRobot("FSM started runID=\(shortRunID(runID)) currentState=\(currentState.rawValue)")
        
        scheduleFSMTransition(after: 1.0, runID: runID, reason: "start")
    }
    
    func stopFSM() {
        fsmActive = false
        fsmRunID = UUID()
        scheduledFSMRunID = nil
        clearPreClosureState()
        isNudging = false
        isAwaitingInteractionAcceptance = false
        currentInteractionInvitationId = nil
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        acceptanceWindowStartedAt = nil
        sendCommand(for: .guardPose)
        logRobot("FSM stopped newRunID=\(shortRunID(fsmRunID))")
    }

    func cancelRobotActivityWithoutCommand() {
        fsmActive = false
        fsmRunID = UUID()
        scheduledFSMRunID = nil
        clearPreClosureState()
        isNudging = false
        isAwaitingInteractionAcceptance = false
        currentInteractionInvitationId = nil
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        logRobot("activity cancelled without sending a command")
    }

    func nudgeForRevitalisation() {
        guard !isNudging else {
            logRobot("revitalisation nudge ignored: nudge already in progress")
            return
        }

        setup()
        isNudging = true
        logRobot("revitalisation nudge started")

        fsmActive = false
        fsmRunID = UUID()
        scheduledFSMRunID = nil
        clearPreClosureState()
        isAwaitingInteractionAcceptance = false
        currentInteractionInvitationId = nil
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil

        let sequence: [(RobotCommand.State, TimeInterval)] = [
            (.guardPose, 0.5),
            (.idle, 0.5),
            (.prePunch, 0.5),
            (.idle, 0.5),
            (.dodgeLeft, 0.7),
            (.guardPose, 0.7)
        ]

        runNudgeStep(sequence, index: 0)
    }

    func beginPreClosure(duration: TimeInterval, completion: @escaping () -> Void) {
        guard fsmActive else {
            logRobot("pre-closure requested while FSM inactive; completing immediately")
            completion()
            return
        }

        guard preClosureStartedAt == nil else {
            logRobot("pre-closure ignored: already active")
            return
        }

        preClosureStartedAt = Date()
        preClosureDuration = duration
        logRobot("pre-closure started duration=\(Int(duration))s")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.preClosureStartedAt != nil else { return }
            self.logRobot("pre-closure completed")
            self.clearPreClosureState()
            completion()
        }
    }
    
    // MARK: - FSM Logic
    private func transitionFSM(runID: UUID? = nil) {
        let activeRunID = runID ?? fsmRunID
        if scheduledFSMRunID == activeRunID {
            scheduledFSMRunID = nil
        }

        guard fsmActive, !isNudging, activeRunID == fsmRunID else {
            logRobot("FSM transition skipped fsmActive=\(fsmActive) isNudging=\(isNudging) activeRunID=\(shortRunID(activeRunID)) currentRunID=\(shortRunID(fsmRunID))")
            return
        }

        // If contact detected — always return to guard immediately
        if objectDetected {
            if currentState != .guardPose {
                currentState = .guardPose
                sendCommand(for: .guardPose)
                logRobot("contact detected: switching to Guard Pose runID=\(shortRunID(activeRunID))")
            }

            // Stay in guard for 2.5 seconds before resuming
            scheduleFSMTransition(after: 1.0, runID: activeRunID, reason: "contactGuard")
            return
        }

        var nextState: RobotCommand.State
        var delay: TimeInterval

        switch currentState {
        /*case .idle:
            if(userAction != .none){
                switch userAction {
                case .jab:        nextState = .guardPose
                case .hook:       nextState = .guardPose
                case .uppercut:   nextState = .guardPose
                case .dodgeLeft:  nextState = .dodgeLeft
                case .dodgeRight: nextState = .dodgeRight
                case .block:
                    let choices: [(RobotCommand.State, TimeInterval)] = [
                        (.prePunch, 0.3),
                        (.preHookLeft, 0.3),
                        (.preHookRight, 0.3)
                    ]
                    (nextState, delay) = choices.randomElement()!
                case .none:       fatalError("Impossible")
                }
                delay = 0.8
                
            }else{
                nextState = .guardPose
                delay = 1.0
            }

        case .guardPose:
            // Randomly choose next offensive action
            if(userAction != .none){
                switch userAction {
                case .jab:        nextState = .guardPose
                case .hook:       nextState = .guardPose
                case .uppercut:   nextState = .guardPose
                case .dodgeLeft:  nextState = .dodgeLeft
                case .dodgeRight: nextState = .dodgeRight
                case .block:
                    let choices: [(RobotCommand.State, TimeInterval)] = [
                        (.prePunch, 0.3),
                        (.preHookLeft, 0.3),
                        (.preHookRight, 0.3)
                    ]
                    (nextState, delay) = choices.randomElement()!
                case .none:       fatalError("Impossible")
                }
                delay = 0.8
                
            }else{
                let choices: [(RobotCommand.State, TimeInterval)] = [
                    (.prePunch, 0.3),
                    (.preHookLeft, 0.3),
                    (.preHookRight, 0.3),
                    (.dodgeLeft, 0.5),
                    (.dodgeRight, 0.5)
                ]
                (nextState, delay) = choices.randomElement()!
            }*/
        
        case .idle:
            nextState = .guardPose
            delay = 1.0
        case .guardPose:
            // Randomly choose next offensive action
            let choices: [(RobotCommand.State, TimeInterval)] = [ (.prePunch, 0.3), (.preHookLeft, 0.3), (.preHookRight, 0.3), (.dodgeLeft, 0.5), (.dodgeRight, 0.5) ]
            (nextState, delay) = choices.randomElement()!
            
        
        case .prePunch:
            nextState = .punch
            delay = 0.5

        case .punch:
            nextState = .idle
            delay = 1.0

        case .preHookLeft, .preHookRight:
            nextState = .hook
            delay = 0.8

        case .hook:
            nextState = .idle
            delay = 1.0

        case .preUppercut:
            nextState = .uppercut
            delay = 1.2

        case .uppercut:
            nextState = .idle
            delay = 1.0

        case .dodgeLeft, .dodgeRight:
            nextState = .idle
            delay = 0.5
        }

        // Send command and schedule the next transition
        currentState = nextState
        sendCommand(for: nextState)
        logRobot("FSM transitioned state=\(currentState.rawValue) delay=\(String(format: "%.2f", delay))s runID=\(shortRunID(activeRunID))")

        scheduleFSMTransition(after: adjustedFSMDelay(delay), runID: activeRunID, reason: "stateDelay")
    }

    private func scheduleFSMTransition(after delay: TimeInterval, runID: UUID, reason: String) {
        guard fsmActive, !isNudging, runID == fsmRunID else {
            logRobot("FSM schedule skipped reason=\(reason) fsmActive=\(fsmActive) isNudging=\(isNudging) runID=\(shortRunID(runID)) currentRunID=\(shortRunID(fsmRunID))")
            return
        }

        guard scheduledFSMRunID != runID else {
            logRobot("FSM schedule ignored reason=\(reason) alreadyScheduled runID=\(shortRunID(runID))")
            return
        }

        scheduledFSMRunID = runID
        logRobot("FSM scheduled reason=\(reason) delay=\(String(format: "%.2f", delay))s runID=\(shortRunID(runID))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.fsmActive, runID == self.fsmRunID else { return }
            if self.scheduledFSMRunID == runID {
                self.scheduledFSMRunID = nil
            }

            if reason == "contactGuard" {
                self.objectDetected = false
            }
            self.transitionFSM(runID: runID)
        }
    }

    private func adjustedFSMDelay(_ baseDelay: TimeInterval) -> TimeInterval {
        guard let preClosureStartedAt, preClosureDuration > 0 else { return baseDelay }

        let progress = min(1.0, max(0.0, Date().timeIntervalSince(preClosureStartedAt) / preClosureDuration))
        let multiplier = 1.0 + (progress * 2.0)
        let adjustedDelay = baseDelay * multiplier
        logRobot("pre-closure speed reduction progress=\(String(format: "%.2f", progress)) delay=\(String(format: "%.2f", baseDelay))->\(String(format: "%.2f", adjustedDelay))")
        return adjustedDelay
    }

    private func clearPreClosureState() {
        preClosureStartedAt = nil
        preClosureDuration = 0
    }


    private func sendCommand(for state: RobotCommand.State) {
        let command = RobotCommand(state: state)
        let dict: [String: Any] = [
            "T": command.T,
            "base": command.base,
            "shoulder": command.shoulder,
            "elbow": command.elbow,
            "hand": command.hand,
            "spd": command.spd,
            "acc": command.acc
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonPayload = String(data: data, encoding: .utf8),
              let jsonStr = jsonPayload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://\(robotIP)/js?json=\(jsonStr)") else {
            logRobot("command build failed state=\(state.rawValue) payload=\(dict)")
            return
        }

        robotCommandSequence += 1
        let commandId = "R\(robotCommandSequence)"
        let startedAt = Date()
        logRobot("HTTP SEND id=\(commandId) state=\(state.rawValue) runID=\(shortRunID(fsmRunID)) fsmActive=\(fsmActive) isNudging=\(isNudging) awaitingAcceptance=\(isAwaitingInteractionAcceptance) payload=\(jsonPayload) url=\(url.absoluteString)")

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let responseText = data
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clippedResponse = responseText.map { String($0.prefix(160)) } ?? "nil"

            if let error {
                self?.logRobot("HTTP FAIL id=\(commandId) state=\(state.rawValue) elapsedMs=\(elapsedMs) error=\(error.localizedDescription)")
            } else {
                self?.logRobot("HTTP DONE id=\(commandId) state=\(state.rawValue) elapsedMs=\(elapsedMs) status=\(statusCode.map(String.init) ?? "nil") response=\(clippedResponse)")
            }
        }.resume()
    }

    private func runNudgeStep(_ sequence: [(RobotCommand.State, TimeInterval)], index: Int) {
        guard isNudging else { return }
        guard index < sequence.count else {
            isNudging = false
            beginInteractionAcceptanceWindow()
            logRobot("revitalisation nudge complete; waiting for hand acceptance")
            return
        }

        let (state, delay) = sequence[index]
        currentState = state
        sendCommand(for: state)
        logRobot("revitalisation nudge step=\(index + 1)/\(sequence.count) state=\(state.rawValue) nextDelay=\(String(format: "%.2f", delay))s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.runNudgeStep(sequence, index: index + 1)
        }
    }

    private func beginInteractionAcceptanceWindow() {
        isAwaitingInteractionAcceptance = true
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        let windowStartedAt = Date()
        acceptanceWindowStartedAt = windowStartedAt
        acceptanceToFUpdateCount = 0
        acceptanceTrueCount = 0
        acceptanceFalseCount = 0
        let invitationId = "interaction-\(Int(windowStartedAt.timeIntervalSince1970 * 1000))"
        currentInteractionInvitationId = invitationId
        holdGuardPose()
        logRobot("acceptance window started duration=\(Int(interactionAcceptanceWindowSeconds))s objectDetected=\(objectDetected)")
        DataRecordingManager.shared.recordInteractionInvitation(
            invitationId: invitationId,
            windowSeconds: interactionAcceptanceWindowSeconds,
            holdSeconds: handAcceptanceHoldSeconds,
            objectDetectedAtStart: objectDetected,
            timestampS: windowStartedAt.timeIntervalSince1970
        )
        NotificationCenter.default.post(
            name: .interactionInvitationWaiting,
            object: nil,
            userInfo: [
                "windowSeconds": interactionAcceptanceWindowSeconds,
                "holdSeconds": handAcceptanceHoldSeconds
            ]
        )

        if objectDetected {
            updateInteractionAcceptance(detected: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interactionAcceptanceWindowSeconds) {
            guard self.isAwaitingInteractionAcceptance else { return }
            self.rejectInteraction(reason: self.acceptanceRejectionReason())
        }
    }

    private func holdGuardPose() {
        currentState = .guardPose
        sendCommand(for: .guardPose)
    }

    private func handleObjectDetection(_ detected: Bool) {
        if isAwaitingInteractionAcceptance {
            objectDetected = detected
            logRobot("ToF update objectDetected=\(detected) awaitingAcceptance=true fsmActive=\(fsmActive)")
            updateInteractionAcceptance(detected: detected)
            return
        }

        if fsmActive {
            logRobot("ToF ignored during active FSM objectDetected=\(detected)")
            return
        }

        objectDetected = detected
        logRobot("ToF standby update objectDetected=\(detected)")
    }

    private func updateInteractionAcceptance(detected: Bool) {
        acceptanceToFUpdateCount += 1
        if detected {
            acceptanceTrueCount += 1
            lastHandDetectedAt = Date()
            if handPresenceStartedAt == nil {
                let startedAt = Date()
                handPresenceStartedAt = startedAt
                logRobot("hand detected; hold for \(handAcceptanceHoldSeconds)s to accept interaction")
                scheduleAcceptanceCheck(startedAt: startedAt)
            }

            guard let handPresenceStartedAt,
                  Date().timeIntervalSince(handPresenceStartedAt) >= handAcceptanceHoldSeconds
            else { return }

            acceptInteraction()
        } else {
            acceptanceFalseCount += 1
            scheduleHandDropoutCheck()
        }
    }

    private func acceptanceRejectionReason() -> String {
        let elapsed = acceptanceWindowStartedAt.map { Date().timeIntervalSince($0) } ?? interactionAcceptanceWindowSeconds
        if acceptanceToFUpdateCount == 0 {
            return "no ToF updates received during \(Int(elapsed))s acceptance window"
        }
        if acceptanceTrueCount == 0 {
            return "ToF did not detect a hand during \(Int(elapsed))s window (\(acceptanceFalseCount) false reading(s))"
        }

        let heldFor = handPresenceStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return "hand detected but not held for \(Int(handAcceptanceHoldSeconds))s (true=\(acceptanceTrueCount), false=\(acceptanceFalseCount), currentHold=\(String(format: "%.1f", heldFor))s)"
    }

    private func scheduleAcceptanceCheck(startedAt: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + handAcceptanceHoldSeconds) {
            guard self.isAwaitingInteractionAcceptance,
                  self.handPresenceStartedAt == startedAt
            else { return }

            let now = Date()
            let hasRecentHandDetection = self.objectDetected ||
                self.lastHandDetectedAt.map { now.timeIntervalSince($0) <= self.handAcceptanceDropoutGraceSeconds } == true
            guard hasRecentHandDetection else { return }

            self.acceptInteraction()
        }
    }

    private func scheduleHandDropoutCheck() {
        guard handPresenceStartedAt != nil else { return }
        let lastDetectedAt = lastHandDetectedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + handAcceptanceDropoutGraceSeconds) {
            guard self.isAwaitingInteractionAcceptance,
                  self.handPresenceStartedAt != nil,
                  !self.objectDetected,
                  self.lastHandDetectedAt == lastDetectedAt
            else { return }

            self.logRobot("hand hold interrupted for \(self.handAcceptanceDropoutGraceSeconds)s; acceptance still open")
            self.handPresenceStartedAt = nil
            self.lastHandDetectedAt = nil
        }
    }

    private func acceptInteraction() {
        guard isAwaitingInteractionAcceptance else { return }
        recordInteractionInvitationResponse(
            response: "accepted",
            source: "robotHandHold",
            reason: nil
        )
        isAwaitingInteractionAcceptance = false
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        acceptanceWindowStartedAt = nil
        acceptanceToFUpdateCount = 0
        acceptanceTrueCount = 0
        acceptanceFalseCount = 0
        objectDetected = false
        logRobot("interaction accepted by hand hold")
        NotificationCenter.default.post(name: .interactionAccepted, object: nil)
        Detector.shared.recordBreakAccepted(source: "robotHandHold")
        TimerController.shared.startTimer(reset: true)
        DeskActivityManager.shared.pauseCurrentBout(
            reason: "interactionAccepted",
            source: "robotHandHold"
        )
        startFSM()
    }

    private func rejectInteraction(reason: String) {
        guard isAwaitingInteractionAcceptance else { return }
        recordInteractionInvitationResponse(
            response: "rejected",
            source: "robotToF",
            reason: reason
        )
        isAwaitingInteractionAcceptance = false
        handPresenceStartedAt = nil
        lastHandDetectedAt = nil
        acceptanceWindowStartedAt = nil
        acceptanceToFUpdateCount = 0
        acceptanceTrueCount = 0
        acceptanceFalseCount = 0
        holdGuardPose()
        Detector.shared.recordBreakIgnored(source: "robotToF")
        logRobot("interaction rejected: \(reason)")
        NotificationCenter.default.post(
            name: .interactionRejected,
            object: nil,
            userInfo: ["reason": reason]
        )
    }

    private func recordInteractionInvitationResponse(
        response: String,
        source: String,
        reason: String?
    ) {
        guard let invitationId = currentInteractionInvitationId else { return }
        DataRecordingManager.shared.recordInteractionInvitationResponse(
            invitationId: invitationId,
            response: response,
            source: source,
            reason: reason,
            tofUpdateCount: acceptanceToFUpdateCount,
            tofTrueCount: acceptanceTrueCount,
            tofFalseCount: acceptanceFalseCount
        )
        currentInteractionInvitationId = nil
    }
    
    func receiveIMU(_ imu: IMUData) {
        latestIMU = imu
        processIMU(imu)
    }
    
    /*private func processIMU(_ imu: IMUData) {
        guard fsmActive else { return }
        
        // Append to buffer
        imuBuffer.append(imu)
        if imuBuffer.count > bufferSize { imuBuffer.removeFirst() }
        
        // Compute deltas from first in buffer
        guard let first = imuBuffer.first else { return }
        let deltaX = imu.ax - first.ax
        let deltaY = imu.ay - first.ay
        let deltaZ = imu.az - first.az
        let deltaRoll = imu.roll - first.roll
        let deltaPitch = imu.pitch - first.pitch
        let deltaYaw = imu.yaw - first.yaw
        
        var action: UserAction = .block
        
        // --- Jab: forward acceleration dominant ---
        if deltaX > 0.3 && abs(deltaPitch) < 0.3 && abs(deltaRoll) < 0.3 {
            action = .jab
        }
        // --- Uppercut: vertical acceleration dominant ---
        else if deltaZ > 0.3 && deltaPitch > 0.2 {
            action = .uppercut
        }
        // --- Hook: rotation around wrist (yaw) dominant ---
        else if abs(deltaYaw) > 0.2 && abs(deltaRoll) < 0.2 && abs(deltaPitch) < 0.2 {
            action = .hook
        }
        // --- Dodge: big roll movement, small other changes ---
        else if deltaRoll < -0.2 && abs(deltaX) < 0.2 { action = .dodgeLeft }
        else if deltaRoll > 0.2 && abs(deltaX) < 0.2 { action = .dodgeRight }

        userAction = action
        print("📊 User Action transitioned to:", userAction)
    }*/
    
    private func processIMU(_ imu: IMUData) {
        guard fsmActive else { return }

        imuBuffer.append(imu)
        //if imuBuffer.count > windowSize { imuBuffer.removeFirst() }

        if imuBuffer.count < windowSize { return }

        let action = classifyWindow(imuBuffer)
        userAction = action
        imuBuffer.removeAll()
        logRobot("predicted userAction=\(userAction)")
    }

    private func classifyWindow(_ window: [IMUData]) -> UserAction {

        let ax = window.map { $0.ax }
        let ay = window.map { $0.ay }
        let az = window.map { $0.az }

        let roll = window.map { $0.roll }
        let pitch = window.map { $0.pitch }
        let yaw = window.map { $0.yaw }

        // Features
        let maxAX = ax.max() ?? 0
        let maxAZ = az.max() ?? 0
        let yawRange = (yaw.max() ?? 0) - (yaw.min() ?? 0)
        let rollRange = (roll.max() ?? 0) - (roll.min() ?? 0)
        let pitchRange = (pitch.max() ?? 0) - (pitch.min() ?? 0)

        let accelMagnitude = sqrt(maxAX*maxAX + maxAZ*maxAZ)

        // --- JAB ---
        if maxAX > 0.8 && pitchRange < 0.25 && rollRange < 0.25 {
            return .jab
        }

        // --- UPPERCUT ---
        if maxAZ > 0.7 && pitchRange > 0.3 {
            return .uppercut
        }

        // --- HOOK ---
        if yawRange > 0.5 && pitchRange < 0.3 {
            return .hook
        }

        // --- DODGE LEFT/RIGHT ---
        if rollRange > 0.5 {
            let avgRoll = roll.reduce(0,+) / Double(roll.count)
            if avgRoll < -0.2 { return .dodgeLeft }
            if avgRoll >  0.2 { return .dodgeRight }
        }

        return .block
    }

    private func logRobot(_ message: String) {
        print("🤖 [\(Self.logTimestamp())] \(message)")
    }

    private func shortRunID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func logTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

}
