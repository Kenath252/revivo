//
//  ModeTimerView.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import SwiftUI
import WatchConnectivity

struct ModeTimerView: View {
    let mode: RobotMode
    @State private var isRunning = false
    @State private var didSendSelection = false
    @State private var displayTick = Date()
    @StateObject private var workoutManager = WorkoutManager.shared
    @StateObject private var watchSessionManager = WatchSessionManager.shared
    private let displayRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(mode.rawValue.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 6)

                VStack(spacing: 3) {
                    Text(phoneTimeLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))

                    Text(formattedDuration(phoneDisplaySeconds))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.9)))

                if isInteractionActiveBreak {
                    Button(action: {
                        isRunning = false
                        sendMessageToPhone("stop")
                        IMUManager.shared.stopSendingIMU()
                        workoutManager.stopWorkout()
                    }) {
                        Text("Emergency Stop")
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color.red.opacity(0.28))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red, lineWidth: 2))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                } else if !isBaselineActiveBreak {
                    // Start / Pause
                    Button(action: {
                        let shouldStart = !isSessionRunning
                        isRunning = shouldStart
                        sendMessageToPhone(shouldStart ? "start" : "pause")
                        if shouldStart {
                            workoutManager.startWorkout()
                            IMUManager.shared.startSendingIMU { imuData in
                                WatchSessionManager.shared.sendIMUData(imuData)
                            }
                        } else {
                            workoutManager.pauseWorkout()
                            IMUManager.shared.stopSendingIMU()
                        }
                    }) {
                        Text(isSessionRunning ? "Pause" : "Start")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Color.black)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(isSessionRunning ? Color.yellow : Color.green, lineWidth: 2))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }

                if !isInteractionActiveBreak {
                    // Stop
                    Button(action: {
                        if isBaselineActiveBreak {
                            watchSessionManager.isActiveBreakRunning = false
                            sendMessageToPhone("stopBreak")
                        } else {
                            isRunning = false
                            sendMessageToPhone("stop")
                            IMUManager.shared.stopSendingIMU()
                            workoutManager.stopWorkout()
                        }

                    }) {
                        Text(isBaselineActiveBreak ? "Stop Break" : "Stop")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Color.black)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red, lineWidth: 2))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(LinearGradient(colors: [Color.black, Color(red: 0.1, green: 0, blue: 0)], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
        .onAppear {
            isRunning = isPhoneSessionRunning
            if !didSendSelection, shouldSendSelectionOnAppear {
                didSendSelection = true
                WatchSessionManager.shared.sendCommand(selectionCommand, mode: commandMode)
            }
        }
        .onChange(of: watchSessionManager.phoneCurrentCommand) { _, _ in
            isRunning = isPhoneSessionRunning
        }
        .onChange(of: watchSessionManager.phoneBreakTimerRunning) { _, _ in
            displayTick = Date()
            isRunning = isPhoneSessionRunning
        }
        .onChange(of: watchSessionManager.phoneBreakElapsedSeconds) { _, _ in
            displayTick = Date()
        }
        .onReceive(displayRefreshTimer) { now in
            guard shouldLocallyAdvanceDisplayedTime else { return }
            displayTick = now
        }
    }
    
    private func sendMessageToPhone(_ command: String) {
        WatchSessionManager.shared.sendCommand(command, mode: commandMode)
    }

    private var selectionCommand: String {
        if commandMode == .baseline {
            return "selectBaseline"
        }

        switch mode {
        case .interactive:
            return "selectInteraction"
        case .baseline, .personalisation:
            return "selectPersonalisation"
        }
    }

    private var commandMode: RobotMode {
        mode
    }

    private var isBaselineActiveBreak: Bool {
        commandMode == .baseline && watchSessionManager.isActiveBreakRunning
    }

    private var isInteractionActiveBreak: Bool {
        commandMode == .interactive && watchSessionManager.phoneBreakTimerRunning
    }

    private var isPhoneSessionRunning: Bool {
        watchSessionManager.phoneBreakTimerRunning ||
            ["start", "stopBreak"].contains(watchSessionManager.phoneCurrentCommand)
    }

    private var isSessionRunning: Bool {
        isRunning || isPhoneSessionRunning
    }

    private var shouldSendSelectionOnAppear: Bool {
        guard watchSessionManager.phoneCurrentMode == commandMode.rawValue else { return true }
        return !["start", "pause", "stopBreak"].contains(watchSessionManager.phoneCurrentCommand)
    }

    private var phoneTimeLabel: String {
        watchSessionManager.phoneBreakTimerRunning ? "Active Break" : "Current Bout"
    }

    private var phoneDisplaySeconds: TimeInterval {
        if watchSessionManager.phoneBreakTimerRunning {
            return watchSessionManager.phoneBreakElapsedSeconds + localElapsedSinceLastPhoneStatus
        }

        return watchSessionManager.phoneCurrentDeskBoutSeconds +
            (shouldLocallyAdvanceDeskBout ? localElapsedSinceLastPhoneStatus : 0)
    }

    private var shouldLocallyAdvanceDisplayedTime: Bool {
        watchSessionManager.phoneBreakTimerRunning || shouldLocallyAdvanceDeskBout
    }

    private var shouldLocallyAdvanceDeskBout: Bool {
        !watchSessionManager.phoneBreakTimerRunning &&
            watchSessionManager.phoneCurrentDeskBoutSeconds > 0 &&
            ["start", "stopBreak"].contains(watchSessionManager.phoneCurrentCommand)
    }

    private var localElapsedSinceLastPhoneStatus: TimeInterval {
        let statusAnchorS = watchSessionManager.phoneStatusSentAtS > 0
            ? watchSessionManager.phoneStatusSentAtS
            : watchSessionManager.phoneStatusReceivedAtS
        return statusAnchorS > 0
            ? max(0, displayTick.timeIntervalSince1970 - statusAnchorS)
            : 0
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
