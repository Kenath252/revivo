import SwiftUI

struct PersonalisationView: View {
    @StateObject private var watchSessionManager = WatchSessionManager.shared
    @State private var personalisationState: PersonalisationState = .ready
    @State private var isShowingStartConfirmation = false
    @State private var isShowingStopConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("PERSONALISATION")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 6)

                Text(personalisationState.statusText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.9)))

                Button {
                    handlePrimaryAction()
                } label: {
                    Text(personalisationState.primaryButtonTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(personalisationState.primaryColor, lineWidth: 2)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button {
                    isShowingStopConfirmation = true
                } label: {
                    Text("Stop")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red, lineWidth: 2)
                        )
                        .foregroundColor(.white)
                }
                .disabled(personalisationState == .ready)
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0, blue: 0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
        .onAppear {
            syncPersonalisationStateFromPhone()
            if !isPersonalisationInProgressOnPhone {
                watchSessionManager.sendCommand("selectPersonalisation", mode: RobotMode.personalisation)
            }
        }
        .onChange(of: watchSessionManager.phoneCurrentCommand) { _, _ in
            syncPersonalisationStateFromPhone()
        }
        .confirmationDialog(
            "Start personalisation?",
            isPresented: $isShowingStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Personalisation") {
                personalisationState = .running
                watchSessionManager.sendCommand("startPersonalisation", mode: RobotMode.personalisation)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Begin the Day 1 baseline recording session.")
        }
        .confirmationDialog(
            "Stop personalisation?",
            isPresented: $isShowingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop and Build Baseline", role: .destructive) {
                personalisationState = .ready
                watchSessionManager.sendCommand("stopPersonalisation", mode: RobotMode.personalisation)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("End recording and create the baseline profile from collected data.")
        }
    }

    private func handlePrimaryAction() {
        switch personalisationState {
        case .ready:
            isShowingStartConfirmation = true
        case .running:
            personalisationState = .paused
            watchSessionManager.sendCommand("pausePersonalisation", mode: RobotMode.personalisation)
        case .paused:
            personalisationState = .running
            watchSessionManager.sendCommand("startPersonalisation", mode: RobotMode.personalisation)
        }
    }

    private var isPersonalisationInProgressOnPhone: Bool {
        ["startPersonalisation", "pausePersonalisation"].contains(watchSessionManager.phoneCurrentCommand)
    }

    private func syncPersonalisationStateFromPhone() {
        switch watchSessionManager.phoneCurrentCommand {
        case "startPersonalisation":
            personalisationState = .running
        case "pausePersonalisation":
            personalisationState = .paused
        default:
            personalisationState = .ready
        }
    }
}

private enum PersonalisationState {
    case ready
    case running
    case paused

    var statusText: String {
        switch self {
        case .ready:
            "Ready to personalise"
        case .running:
            "Personalisation running"
        case .paused:
            "Personalisation paused"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .ready:
            "Start Personalisation"
        case .running:
            "Pause"
        case .paused:
            "Resume"
        }
    }

    var primaryColor: Color {
        switch self {
        case .ready:
            .green
        case .running:
            .yellow
        case .paused:
            .orange
        }
    }
}
