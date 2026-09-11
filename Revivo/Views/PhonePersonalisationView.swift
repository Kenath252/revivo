import SwiftUI
import UIKit

struct PhonePersonalisationView: View {
    @ObservedObject private var wcManager = PhoneWCManager.shared
    @AppStorage("userName") private var userName = "Desk Boxer"
    @State private var questionnaireTimer: Timer?
    @State private var isShowingSEQ = false
    @State private var seqResponses = SEQQuestionnaire.defaultResponses
    @State private var seqPromptedAtS = Date().timeIntervalSince1970

    private let questionnaireIntervalS: TimeInterval = 25 * 60
    private let seqPromptTitle = "SEQ Check-in"
    private let seqPromptBody = "During the last 25 minutes, how have you felt?"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0, blue: 0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("PERSONALISATION")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .red.opacity(0.8), radius: 8)

                Text(statusText)
                    .font(.title2.bold())
                    .foregroundColor(statusColor)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(statusColor.opacity(0.8), lineWidth: 2)
                    )

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 70)

            if isShowingSEQ {
                SEQQuestionnaireOverlay(
                    responses: $seqResponses,
                    onSubmit: submitSEQResponse
                )
            }
        }
        .onAppear {
            updateQuestionnaireTimer(for: wcManager.currentCommand)
        }
        .onDisappear {
            stopQuestionnaireTimer()
        }
        .onChange(of: wcManager.currentCommand) { newCommand in
            updateQuestionnaireTimer(for: newCommand)
        }
        .onReceive(NotificationCenter.default.publisher(for: .seqPromptNotificationTapped)) { notification in
            let promptId = notification.userInfo?["promptId"] as? String
                ?? PhoneWCManager.seqPromptNotificationIdentifier
            presentSEQPrompt(promptId: promptId, shouldNotifyDevices: false)
        }
    }

    private var statusText: String {
        wcManager.currentCommand == "startPersonalisation" ? "RUNNING" : "READY"
    }

    private var statusColor: Color {
        wcManager.currentCommand == "startPersonalisation" ? .green : .yellow
    }

    private func updateQuestionnaireTimer(for command: String?) {
        if command == "startPersonalisation" {
            startQuestionnaireTimerIfNeeded()
        } else {
            stopQuestionnaireTimer()
        }
    }

    private func startQuestionnaireTimerIfNeeded() {
        guard questionnaireTimer == nil else { return }

        PhoneWCManager.shared.prepareSEQPromptNotifications()
        scheduleNextSEQNotification()
        questionnaireTimer = Timer.scheduledTimer(withTimeInterval: questionnaireIntervalS, repeats: true) { _ in
            presentSEQPrompt()
        }
    }

    private func stopQuestionnaireTimer() {
        questionnaireTimer?.invalidate()
        questionnaireTimer = nil
        isShowingSEQ = false
        PhoneWCManager.shared.cancelSEQPromptNotifications()
    }

    private func submitSEQResponse() {
        if wcManager.currentCommand == "startPersonalisation",
           DataRecordingManager.shared.currentRecordingMode() != .personalisation {
            DataRecordingManager.shared.start(
                mode: .personalisation,
                participantId: participantId(from: userName)
            )
        }

        let scores = SEQQuestionnaire.scores(from: seqResponses)
        DataRecordingManager.shared.recordSEQResponse(
            responses: seqResponses,
            stressScore: scores.stress,
            energyScore: scores.energy,
            promptedAtS: seqPromptedAtS,
            submittedAtS: Date().timeIntervalSince1970
        )
        isShowingSEQ = false
        scheduleNextSEQNotification()
    }

    private func participantId(from userName: String) -> String {
        let sanitized = userName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()

        return sanitized.isEmpty ? "participant" : sanitized
    }

    private func presentSEQPrompt(
        promptId: String = PhoneWCManager.seqPromptNotificationIdentifier,
        shouldNotifyDevices: Bool = true
    ) {
        seqPromptedAtS = Date().timeIntervalSince1970
        seqResponses = SEQQuestionnaire.defaultResponses
        isShowingSEQ = true

        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if shouldNotifyDevices {
            PhoneWCManager.shared.notifySEQPromptPresented(
                title: seqPromptTitle,
                body: seqPromptBody,
                promptId: promptId
            )
        }
        PhoneWCManager.shared.cancelSEQPromptNotifications()
    }

    private func scheduleNextSEQNotification() {
        guard wcManager.currentCommand == "startPersonalisation" else { return }
        PhoneWCManager.shared.scheduleSEQPromptNotification(
            title: seqPromptTitle,
            body: seqPromptBody,
            promptId: PhoneWCManager.seqPromptNotificationIdentifier,
            after: questionnaireIntervalS
        )
    }
}

private struct SEQQuestionnaireOverlay: View {
    @Binding var responses: [String: Int]
    let onSubmit: () -> Void

    var body: some View {
        Color.black.opacity(0.65)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 18) {
                    Text("SEQ")
                        .font(.title.bold())
                        .foregroundColor(.white)

                    Text("During the last 30 minutes, how have you felt?")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.9))

                    HStack {
                        Text("0 Not at all")
                        Spacer()
                        Text("5 Very much")
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))

                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(SEQQuestionnaire.items, id: \.id) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.white)

                                    Picker(item.label, selection: binding(for: item.id)) {
                                        ForEach(SEQQuestionnaire.responseOptions, id: \.score) { option in
                                            Text(option.shortLabel).tag(option.score)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 430)

                    Button(action: onSubmit) {
                        Text("Submit")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.green.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(22)
                .background(Color.black.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.55), lineWidth: 1.5)
                )
                .padding(.horizontal, 22)
            }
    }

    private func binding(for itemId: String) -> Binding<Int> {
        Binding(
            get: { responses[itemId] ?? 0 },
            set: { responses[itemId] = $0 }
        )
    }
}

private enum SEQQuestionnaire {
    static let items: [SEQItem] = [
        SEQItem(id: "rested", label: "Rested", dimension: .stress, shouldReverse: false),
        SEQItem(id: "relaxed", label: "Relaxed", dimension: .stress, shouldReverse: false),
        SEQItem(id: "calm", label: "Calm", dimension: .stress, shouldReverse: false),
        SEQItem(id: "tense", label: "Tense", dimension: .stress, shouldReverse: true),
        SEQItem(id: "stressed", label: "Stressed", dimension: .stress, shouldReverse: true),
        SEQItem(id: "pressured", label: "Pressured", dimension: .stress, shouldReverse: true),
        SEQItem(id: "active", label: "Active", dimension: .energy, shouldReverse: false),
        SEQItem(id: "energetic", label: "Energetic", dimension: .energy, shouldReverse: false),
        SEQItem(id: "focused", label: "Focused", dimension: .energy, shouldReverse: false),
        SEQItem(id: "dull", label: "Dull", dimension: .energy, shouldReverse: true),
        SEQItem(id: "inefficient", label: "Inefficient", dimension: .energy, shouldReverse: true),
        SEQItem(id: "passive", label: "Passive", dimension: .energy, shouldReverse: true)
    ]

    static let responseOptions: [(score: Int, shortLabel: String)] = [
        (0, "0"),
        (1, "1"),
        (2, "2"),
        (3, "3"),
        (4, "4"),
        (5, "5")
    ]

    static var defaultResponses: [String: Int] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) })
    }

    static func scores(from responses: [String: Int]) -> (stress: Double, energy: Double) {
        let stress = score(for: .stress, responses: responses)
        let energy = score(for: .energy, responses: responses)
        return (stress, energy)
    }

    private static func score(for dimension: SEQDimension, responses: [String: Int]) -> Double {
        let values = items
            .filter { $0.dimension == dimension }
            .compactMap { item -> Double? in
                guard let rawValue = responses[item.id] else { return nil }
                return Double(item.shouldReverse ? 5 - rawValue : rawValue)
            }

        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(values.count)
    }
}

private struct SEQItem {
    let id: String
    let label: String
    let dimension: SEQDimension
    let shouldReverse: Bool
}

private enum SEQDimension {
    case stress
    case energy
}
