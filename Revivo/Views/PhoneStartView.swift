//
//  ContentView.swift
//  Revivo
//
//  Created by Uduwara Perera on 11/11/2025.
//

import SwiftUI
import UIKit
import WatchConnectivity

struct PhoneStartView: View {
    @StateObject private var wcManager = PhoneWCManager.shared
    @State private var navigateToTimer = false
    @State private var navigateToPersonalisation = false
    @State private var isShowingSettings = false
    @State private var baselineStatusBanner: BaselineStatusBanner?
    @State private var isActiveBreakQuestionnaireRequired = false
    @AppStorage("userName") private var userName = "Desk Boxer"
    @AppStorage("personalisationAccessEnabled") private var personalisationAccessEnabled = false
    @AppStorage("baselineAccessEnabled") private var baselineAccessEnabled = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.black, Color(red: 0.1, green: 0, blue: 0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("🥊 Revivo 🥊")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .red.opacity(0.8), radius: 8)
                        
                        Text("Ready, \(userName)")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.top, 70)
                    
                    HStack {
                        Circle()
                            .fill(WCSession.default.isReachable ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(WCSession.default.isReachable ? "Watch Connected" : "Watch Not Connected")
                            .foregroundColor(.gray)
                    }
                    
                    Text("Select Interaction or Personalisation on Watch.")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.top, 30)
                    
                    Spacer()
                }
                .padding(.horizontal, 14)
                
                if isShowingSettings {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isShowingSettings = false
                            }
                        }
                    
                    HStack {
                        Spacer()
                        
                        PhoneSettingsPanel(isPresented: $isShowingSettings)
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    .ignoresSafeArea(edges: .vertical)
                }

                VStack {
                    if let baselineStatusBanner {
                        BaselineStatusBannerView(status: baselineStatusBanner) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                self.baselineStatusBanner = nil
                            }
                        }
                        .padding(.top, 54)
                        .padding(.horizontal, 16)
                    }

                    HStack {
                        Spacer()
                        
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isShowingSettings = true
                            }
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                                )
                        }
                        .accessibilityLabel("Open settings")
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            .navigationDestination(isPresented: $navigateToTimer) {
                PhoneTimerView(
                        mode: wcManager.currentMode ?? "unknown",
                        command: wcManager.currentCommand ?? "stop"
                    )
            }
            .navigationDestination(isPresented: $navigateToPersonalisation) {
                PhonePersonalisationView()
            }
            .onChange(of: wcManager.currentCommand) { newCommand in
                    switch newCommand {
                    case "selectInteraction":
                        navigateToPersonalisation = false
                        navigateToTimer = true
                    case "selectBaseline":
                        navigateToPersonalisation = false
                        navigateToTimer = true
                    case "start":
                        navigateToPersonalisation = false
                        navigateToTimer = true   // Navigate to timer
                    case "stop":
                        navigateToTimer = isActiveBreakQuestionnaireRequired
                    case "selectPersonalisation":
                        navigateToTimer = false
                        navigateToPersonalisation = true
                    case "startPersonalisation":
                        navigateToTimer = false
                        navigateToPersonalisation = true
                    case "stopPersonalisation":
                        navigateToPersonalisation = false
                    default:
                        break
                    }
            }
            .onAppear {
                PhoneWCManager.shared.updateWatchModeAccess(
                    personalisationEnabled: personalisationAccessEnabled,
                    baselineEnabled: baselineAccessEnabled
                )
                recoverPersonalisationBaselineIfNeeded()
                DataRecordingManager.shared.recoverMissingDailySummaries(
                    participantId: participantId(from: userName)
                )
            }
            .onChange(of: personalisationAccessEnabled) { isEnabled in
                PhoneWCManager.shared.updateWatchModeAccess(
                    personalisationEnabled: isEnabled,
                    baselineEnabled: baselineAccessEnabled
                )
            }
            .onChange(of: baselineAccessEnabled) { isEnabled in
                PhoneWCManager.shared.updateWatchModeAccess(
                    personalisationEnabled: personalisationAccessEnabled,
                    baselineEnabled: isEnabled
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .baselineCalibrationStatusChanged)) { notification in
                guard let message = notification.userInfo?["message"] as? String,
                      let didSucceed = notification.userInfo?["didSucceed"] as? Bool
                else { return }

                if didSucceed {
                    personalisationAccessEnabled = false
                    PhoneWCManager.shared.updatePersonalisationAccess(false)
                }

                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    baselineStatusBanner = BaselineStatusBanner(
                        title: didSucceed ? "Baseline Ready" : "Baseline Not Created",
                        message: message,
                        didSucceed: didSucceed
                    )
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    guard baselineStatusBanner?.message == message else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        baselineStatusBanner = nil
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeBreakCompleted)) { _ in
                isActiveBreakQuestionnaireRequired = true
                navigateToPersonalisation = false
                navigateToTimer = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeBreakQuestionnaireSubmitted)) { _ in
                isActiveBreakQuestionnaireRequired = false
                if wcManager.currentCommand == "stop" {
                    navigateToTimer = false
                }
            }
        }
    }

    private func participantId(from userName: String) -> String {
        let sanitized = userName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()

        return sanitized.isEmpty ? "participant" : sanitized
    }
}

private struct BaselineStatusBanner: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let didSucceed: Bool
}

private struct BaselineStatusBannerView: View {
    let status: BaselineStatusBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.didSucceed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(status.didSucceed ? .green : .yellow)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(status.message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((status.didSucceed ? Color.green : Color.yellow).opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        .onTapGesture(perform: onDismiss)
    }
}

private struct PhoneSettingsPanel: View {
    @Binding var isPresented: Bool

    @AppStorage("userName") private var userName = "Desk Boxer"
    @AppStorage("userRole") private var userRole = "Researcher"
    @AppStorage("deskLocation") private var deskLocation = "Office"
    @AppStorage("focusGoal") private var focusGoal = "Stay energized"
    @AppStorage("personalisationAccessEnabled") private var personalisationAccessEnabled = false
    @AppStorage("baselineAccessEnabled") private var baselineAccessEnabled = false
    @AppStorage("startPersonalisationFresh") private var startPersonalisationFresh = false
    @AppStorage("detectorThresholdOverrideEnabled") private var thresholdOverrideEnabled = false
    @AppStorage("detectorThresholdOverrideValue") private var thresholdOverrideValue = -1.5
    @State private var exportItems: [URL] = []
    @State private var isShowingExportSheet = false
    @State private var exportMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text("Update your profile and session details.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white.opacity(0.85))
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close settings")
                }

                Group {
                    settingsField(title: "User Name", text: $userName, prompt: "Enter your name")
                    settingsField(title: "Role", text: $userRole, prompt: "Researcher, Engineer...")
                    settingsField(title: "Desk Location", text: $deskLocation, prompt: "Lab, Office...")
                    settingsField(title: "Focus Goal", text: $focusGoal, prompt: "What are you working on?")

                    Toggle(isOn: $personalisationAccessEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable personalisation")
                                .foregroundColor(.white)
                            Text("Allow the Watch personalisation button to open the calibration screen.")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    .tint(.red)

                    Toggle(isOn: $baselineAccessEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable baseline mode")
                                .foregroundColor(.white)
                            Text("Show the Watch Baseline button instead of Interaction.")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    .tint(.red)

                    Toggle(isOn: $startPersonalisationFresh) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start fresh next time")
                                .foregroundColor(.white)
                            Text("Ignore earlier personalisation sessions when building the next baseline.")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    .tint(.red)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $thresholdOverrideEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Override detector threshold")
                                    .foregroundColor(.white)
                                Text(thresholdStatusText)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.65))
                            }
                        }
                        .tint(.red)
                        .onChange(of: thresholdOverrideEnabled) { isEnabled in
                            guard isEnabled,
                                  let personalisedThreshold = personalisedThreshold()
                            else { return }
                            thresholdOverrideValue = personalisedThreshold
                        }

                        HStack {
                            Text("Threshold")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(thresholdOverrideEnabled ? .white : .white.opacity(0.45))

                            Spacer()

                            TextField(
                                "Threshold",
                                value: $thresholdOverrideValue,
                                format: .number.precision(.fractionLength(3))
                            )
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .disabled(!thresholdOverrideEnabled)
                            .frame(width: 96)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(thresholdOverrideEnabled ? 0.10 : 0.04))
                            .foregroundColor(thresholdOverrideEnabled ? .white : .white.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(thresholdOverrideEnabled ? 0.18 : 0.08), lineWidth: 1)
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            exportRecordedData()
                        } label: {
                            Label("Export recorded data", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(Color.red.opacity(0.75))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Export recorded data")

                        if let exportMessage {
                            Text(exportMessage)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.02, blue: 0.04), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.red.opacity(0.35))
                .frame(width: 1)
        }
        .sheet(isPresented: $isShowingExportSheet) {
            ActivityView(activityItems: exportItems)
        }
    }

    private func settingsField(title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            TextField(prompt, text: text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private func participantId(from userName: String) -> String {
        let sanitized = userName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()

        return sanitized.isEmpty ? "participant" : sanitized
    }

    private var thresholdStatusText: String {
        guard thresholdOverrideEnabled else {
            if let personalisedThreshold = personalisedThreshold() {
                return "Using personalised value \(String(format: "%.3f", personalisedThreshold))."
            }
            return "Using the personalised baseline value when available."
        }

        return "Testing with manual heart-state threshold; saved personalisation is unchanged."
    }

    private func personalisedThreshold() -> Double? {
        DataRecordingManager.shared
            .loadBaselineProfile(participantId: participantId(from: userName))?
            .calibratedCompositeThreshold
    }

    private func exportRecordedData() {
        do {
            exportItems = try DataRecordingManager.shared.prepareRecordedDataExport(
                participantId: participantId(from: userName)
            )
            exportMessage = "Prepared export folder for \(participantId(from: userName))."
            isShowingExportSheet = true
        } catch {
            exportItems = []
            exportMessage = error.localizedDescription
            isShowingExportSheet = false
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension PhoneStartView {
    func recoverPersonalisationBaselineIfNeeded() {
        let participantId = userName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()

        _ = BaselineCalibrationManager.shared.recoverUnfinishedPersonalisationSessions(
            participantId: participantId.isEmpty ? "participant" : participantId
        )
    }
}
