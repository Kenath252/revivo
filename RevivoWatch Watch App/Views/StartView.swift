//
//  StartView.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//


//
//  StartView.swift
//  Revivo Watch App
//
//  Created by Uduwara Perera on 7/11/2025.
//

import SwiftUI

struct StartView: View {
    @StateObject private var watchSessionManager = WatchSessionManager.shared
    @State private var selectedMode: RobotMode? = nil
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 🖤 Background
                LinearGradient(
                    colors: [Color.black, Color(red: 0.1, green: 0, blue: 0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                // In StartView.swift

                ScrollView {
                    VStack(spacing: 10) {
                        // Title
                        TitleView()
                            .padding(.top, 6)

                        // Mode Buttons
                        VStack(spacing: 8) {
                            ForEach(visibleModes) { mode in
                                ModeButton(
                                    mode: mode,
                                    selectedMode: $selectedMode,
                                    isLocked: isLocked(mode)
                                )
                            }
                        }
                        .layoutPriority(1)

                        Text("v1.0")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(.gray)
                            .padding(.bottom, 2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
            .navigationDestination(for: RobotMode.self) { mode in
                switch mode {
                case .interactive:
                    ModeTimerView(mode: mode)
                case .baseline:
                    ModeTimerView(mode: mode)
                case .personalisation:
                    PersonalisationView()
                }
            }
        }
        .overlay {
            if watchSessionManager.pendingBaselineBreakId != nil {
                BaselineBreakPromptView(
                    title: watchSessionManager.pendingBaselineBreakTitle,
                    message: watchSessionManager.pendingBaselineBreakBody,
                    onAccept: {
                        watchSessionManager.respondToPendingBaselineBreak("accepted")
                    },
                    onReject: {
                        watchSessionManager.respondToPendingBaselineBreak("rejected")
                    }
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: watchSessionManager.pendingBaselineBreakId)
        .task {
            startBackgroundSensing()
            PhysioManager.shared.startStreaming { data in
                print("📡 HR Stream:", data)
                
                let hr = data["hr"] as? Double
                let hrv = data["hrv"] as? Double
                
                WatchSessionManager.shared.sendPhysioData(hr: hr, hrv: hrv)
            }
        }
    }
    
    private func startBackgroundSensing() {
            WatchSessionManager.shared.activateSession()
            WatchSessionManager.shared.notifyPhoneAppOpened()
            
            // Start workout ONLY if not already running
            WorkoutManager.shared.startWorkout()
    
    }

    private func isLocked(_ mode: RobotMode) -> Bool {
        switch mode {
        case .interactive:
            return isPersonalisationInProgress
        case .baseline:
            return isPersonalisationInProgress || !watchSessionManager.baselineAccessEnabled
        case .personalisation:
            return !watchSessionManager.personalisationAccessEnabled
        }
    }

    private var isPersonalisationInProgress: Bool {
        ["startPersonalisation", "pausePersonalisation"].contains(watchSessionManager.phoneCurrentCommand)
    }

    private var visibleModes: [RobotMode] {
        [
            watchSessionManager.baselineAccessEnabled ? .baseline : .interactive,
            .personalisation
        ]
    }
}

// MARK: - Subviews

struct TitleView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("🥊 Revivo 🥊")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .shadow(color: .red.opacity(0.8), radius: 8, x: 0, y: 0)
            
            Text("Select Mode")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
        }
        .multilineTextAlignment(.center)
    }
}

struct ModeButton: View {
    let mode: RobotMode
    @Binding var selectedMode: RobotMode?
    let isLocked: Bool
    
    var body: some View {
        NavigationLink(value: mode) {
            HStack {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                }

                Text(mode.rawValue.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)

            }
            .frame(minHeight: 34)
            .padding(.horizontal, 8)
            .background(
                ZStack {
                    Color.black.opacity(0.9)
                    LinearGradient(
                        colors: [Color.red.opacity(0.2), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
            )
            .foregroundColor(.white)
            .opacity(isLocked ? 0.45 : 1)
            .blur(radius: isLocked ? 1.2 : 0)
            .scaleEffect(selectedMode == mode ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selectedMode)
        }
        .disabled(isLocked)
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture().onEnded {
                guard !isLocked else { return }
                selectedMode = mode
            }
        )
    }
}

struct BaselineBreakPromptView: View {
    let title: String
    let message: String
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.yellow)

                Text(title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)

                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Respond within 30s")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.58))

                HStack(spacing: 8) {
                    Button(action: onReject) {
                        Text("Reject")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .background(Color.red.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button(action: onAccept) {
                        Text("Accept")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .background(Color.green.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.yellow.opacity(0.8), lineWidth: 1.5)
            )
            .padding(.horizontal, 8)
        }
    }
}
