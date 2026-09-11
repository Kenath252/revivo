//
//  TimerView.swift
//  Revivo
//
//  Created by Uduwara Perera on 11/11/2025.
//

import SwiftUI

struct PhoneTimerView: View {
    let mode: String
    let command: String
    @ObservedObject private var wcManager = PhoneWCManager.shared
    @ObservedObject private var timer = TimerController.shared
    @ObservedObject private var deskActivity = DeskActivityManager.shared
    @ObservedObject private var calendarAvailability = CalendarAvailabilityManager.shared
    @State private var interactionToastTitle: String?
    @State private var interactionToastMessage: String?
    @State private var interactionToastIcon = "bolt.heart.fill"
    @State private var interactionToastColor = Color.yellow
    @State private var activeBreakQuestionnaireContext: ActiveBreakQuestionnaireContext?
    @State private var activeBreakPhysicalActivity = ""
    @State private var activeBreakInteractedStanding = false
    @State private var activeBreakQuestionnaireResponses = PostBreakQuestionnaireCatalog.defaultResponses
    @State private var lastActiveBreakDurationSeconds: TimeInterval = 0
    @State private var displayTick = Date()
    private let displayRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let dailyTotalRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.1, green: 0, blue: 0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            VStack(spacing: 25) {
                Text("Mode: \(mode.uppercased())")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.white)
                    .shadow(color: .red.opacity(0.8), radius: 8)
                    .padding(.top, 40)
                
                VStack(spacing: 12) {
                    Text(primaryTimerLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.72))

                    Text(primaryTimerText)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.8), lineWidth: 2))

                    if isBaselineActiveBreak {
                        Button {
                            PhoneWCManager.shared.stopActiveBreak(source: "phone")
                        } label: {
                            Label("Stop Break", systemImage: "stop.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.78))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // State label
                Text(stateText)
                    .font(.headline)
                    .foregroundColor(stateColor)
                    .padding(.top, 10)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(deskActivity.isWorkingAtDesk ? Color.green : Color.yellow)
                            .frame(width: 10, height: 10)
                        Text(deskActivity.isWorkingAtDesk ? "DESK WORKING" : "DESK UNKNOWN")
                            .font(.headline)
                            .foregroundColor(.white)
                    }

                    Text("Current bout")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))

                    Text(formattedDuration(displayCurrentDeskBoutSeconds))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)

                    Text("Today \(formattedDuration(deskActivity.accumulatedDeskWorkSeconds))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke((deskActivity.isWorkingAtDesk ? Color.green : Color.yellow).opacity(0.8), lineWidth: 1.5)
                )

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(calendarAvailability.isInMeeting ? Color.red : Color.green)
                            .frame(width: 10, height: 10)
                        Text(calendarAvailability.isInMeeting ? "IN MEETING" : "AVAILABLE")
                            .font(.headline)
                            .foregroundColor(.white)
                    }

                    if let meetingTitle = calendarAvailability.currentMeetingTitle,
                       calendarAvailability.isInMeeting {
                        Text(meetingTitle)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    } else {
                        Text(calendarAvailability.authorizationStatusDescription)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke((calendarAvailability.isInMeeting ? Color.red : Color.green).opacity(0.8), lineWidth: 1.5)
                )
                
                Spacer()
            }
            .padding(.horizontal, 18)

            VStack {
                if let interactionToastTitle,
                   let interactionToastMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: interactionToastIcon)
                            .foregroundColor(interactionToastColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(interactionToastTitle)
                                .font(.headline)
                                .foregroundColor(.white)
                            Text(interactionToastMessage)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.78))
                        }

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                clearInteractionToast()
                            }
                        } label: {
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
                            .stroke(interactionToastColor.opacity(0.7), lineWidth: 1)
                    )
                    .padding(.top, 54)
                    .padding(.horizontal, 16)
                }

                Spacer()
            }

            if let activeBreakQuestionnaireContext {
                ActiveBreakQuestionnaireOverlay(
                    context: activeBreakQuestionnaireContext,
                    physicalActivity: $activeBreakPhysicalActivity,
                    interactedStanding: $activeBreakInteractedStanding,
                    responses: $activeBreakQuestionnaireResponses,
                    onSubmit: submitActiveBreakQuestionnaires
                )
            }
        }
        .navigationBarBackButtonHidden(activeBreakQuestionnaireContext != nil)
        .onChange(of: wcManager.currentCommand) { _, newCommand in
            if newCommand == "stop" {
                // Stop -> Navigate back handled in ContentView
            }
        }
        .onAppear {
            deskActivity.refreshDailyTotal()
        }
        .onReceive(dailyTotalRefreshTimer) { _ in
            deskActivity.refreshDailyTotal()
        }
        .onReceive(displayRefreshTimer) { now in
            guard shouldRefreshCurrentBoutDisplay else { return }
            displayTick = now
        }
        .onChange(of: timer.timerState.timeElapsed) { _, newValue in
            if timer.timerState.isRunning {
                lastActiveBreakDurationSeconds = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .revitalisationRequired)) { notification in
            let score = notification.userInfo?["compositeScore"] as? Double
            let triggerReason = notification.userInfo?["triggerReason"] as? String
            let scoreText = score.map { String(format: "Score %.2f", $0) }
                ?? (triggerReason == "prolongedDeskBout" ? "Long desk bout detected" : "Low activation detected")
            let isBaselineMode = wcManager.currentMode == RobotMode.baseline.rawValue

            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showInteractionToast(
                    title: isBaselineMode ? "Activity Break" : "Revitalisation Required",
                    message: isBaselineMode
                        ? "\(scoreText). Do any physical activity you like and revitalise yourself."
                        : "\(scoreText). Robot nudge sent.",
                    icon: isBaselineMode ? "figure.walk" : "bolt.heart.fill",
                    color: .yellow
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .interactionInvitationWaiting)) { notification in
            let windowSeconds = notification.userInfo?["windowSeconds"] as? TimeInterval ?? 15
            let holdSeconds = notification.userInfo?["holdSeconds"] as? TimeInterval ?? 2

            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showInteractionToast(
                    title: "Waiting for Acceptance",
                    message: "Hold hand in front of ToF sensor for \(Int(holdSeconds))s within \(Int(windowSeconds))s.",
                    icon: "hand.raised.fill",
                    color: .blue
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .interactionAccepted)) { _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showInteractionToast(
                    title: "Interaction Accepted",
                    message: "Hand hold detected. Interaction starting.",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .interactionRejected)) { notification in
            let reason = notification.userInfo?["reason"] as? String ?? "acceptance window expired"

            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showInteractionToast(
                    title: "Interaction Rejected",
                    message: reason,
                    icon: "xmark.circle.fill",
                    color: .red
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .baselineBreakResponseRecorded)) { notification in
            guard wcManager.currentMode == RobotMode.baseline.rawValue,
                  let response = notification.userInfo?["response"] as? String,
                  let source = notification.userInfo?["source"] as? String
            else { return }

            let didAccept = response == "accepted"
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showInteractionToast(
                    title: didAccept ? "Break Accepted" : "Break Rejected",
                    message: "Recorded from \(source).",
                    icon: didAccept ? "checkmark.circle.fill" : "xmark.circle.fill",
                    color: didAccept ? .green : .red
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeBreakCompleted)) { notification in
            let completedMode = notification.userInfo?["mode"] as? String ?? wcManager.currentMode ?? mode
            let duration = notification.userInfo?["breakDurationSeconds"] as? TimeInterval
                ?? timer.timerState.timeElapsed
            lastActiveBreakDurationSeconds = duration
            presentActiveBreakQuestionnaires(mode: completedMode, breakDurationSeconds: duration)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeBreakStopped)) { notification in
            let stoppedMode = notification.userInfo?["mode"] as? String ?? wcManager.currentMode ?? mode
            let duration = notification.userInfo?["breakDurationSeconds"] as? TimeInterval
                ?? lastActiveBreakDurationSeconds

            if stoppedMode != RobotMode.baseline.rawValue,
               activeBreakQuestionnaireContext == nil,
               duration > 0 {
                presentActiveBreakQuestionnaires(mode: stoppedMode, breakDurationSeconds: duration)
            }

            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showInteractionToast(
                    title: "Break Stopped",
                    message: "Desk bout tracking has started again.",
                    icon: "stop.circle.fill",
                    color: .red
                )
            }
        }
    }
    
    private var stateText: String {
        switch wcManager.currentCommand {
        case "start": return "RUNNING"
        case "preClosure": return "PRE-CLOSURE"
        case "pause": return "PAUSED"
        case "stopBreak": return "MONITORING"
        default: return "STOPPED"
        }
    }
    
    private var stateColor: Color {
        switch wcManager.currentCommand {
        case "start": return .green
        case "preClosure": return .orange
        case "pause": return .yellow
        case "stopBreak": return .green
        default: return .red
        }
    }

    private var isBaselineActiveBreak: Bool {
        wcManager.currentMode == RobotMode.baseline.rawValue && timer.timerState.isRunning
    }

    private var primaryTimerLabel: String {
        timer.timerState.isRunning ? "Active Break" : "Current Bout"
    }

    private var primaryTimerText: String {
        timer.timerState.isRunning
            ? timer.timerState.timeString
            : formattedDuration(displayCurrentDeskBoutSeconds)
    }

    private var displayCurrentDeskBoutSeconds: TimeInterval {
        _ = displayTick
        return deskActivity.displayCurrentDeskBoutSeconds
    }

    private var shouldRefreshCurrentBoutDisplay: Bool {
        !timer.timerState.isRunning &&
            deskActivity.isWorkingAtDesk &&
            !deskActivity.isBoutPaused
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

    private func showInteractionToast(title: String, message: String, icon: String, color: Color) {
        interactionToastTitle = title
        interactionToastMessage = message
        interactionToastIcon = icon
        interactionToastColor = color
    }

    private func clearInteractionToast() {
        interactionToastTitle = nil
        interactionToastMessage = nil
    }

    private func presentActiveBreakQuestionnaires(mode: String, breakDurationSeconds: TimeInterval) {
        activeBreakPhysicalActivity = ""
        activeBreakInteractedStanding = false
        activeBreakQuestionnaireResponses = PostBreakQuestionnaireCatalog.defaultResponses
        activeBreakQuestionnaireContext = ActiveBreakQuestionnaireContext(
            mode: mode,
            breakDurationSeconds: breakDurationSeconds,
            promptedAtS: Date().timeIntervalSince1970
        )
    }

    private func submitActiveBreakQuestionnaires() {
        guard let activeBreakQuestionnaireContext else { return }

        DataRecordingManager.shared.recordActiveBreakQuestionnaireResponse(
            mode: activeBreakQuestionnaireContext.mode,
            breakDurationSeconds: activeBreakQuestionnaireContext.breakDurationSeconds,
            physicalActivity: activeBreakQuestionnaireContext.requiresPhysicalActivity
                ? activeBreakPhysicalActivity
                : nil,
            interactionPosture: activeBreakQuestionnaireContext.requiresInteractionPosture
                ? (activeBreakInteractedStanding ? "standing" : "seated")
                : nil,
            questionnaireResponses: PostBreakQuestionnaireCatalog.recordedResponses(
                from: activeBreakQuestionnaireResponses
            ),
            promptedAtS: activeBreakQuestionnaireContext.promptedAtS,
            submittedAtS: Date().timeIntervalSince1970
        )

        self.activeBreakQuestionnaireContext = nil
        activeBreakPhysicalActivity = ""
        activeBreakInteractedStanding = false
        NotificationCenter.default.post(name: .activeBreakQuestionnaireSubmitted, object: nil)
    }
}

private struct ActiveBreakQuestionnaireContext {
    let mode: String
    let breakDurationSeconds: TimeInterval
    let promptedAtS: Double

    var requiresPhysicalActivity: Bool {
        mode == RobotMode.baseline.rawValue
    }

    var requiresInteractionPosture: Bool {
        mode == RobotMode.interactive.rawValue
    }
}

private struct ActiveBreakQuestionnaireOverlay: View {
    let context: ActiveBreakQuestionnaireContext
    @Binding var physicalActivity: String
    @Binding var interactedStanding: Bool
    @Binding var responses: [String: Int]
    let onSubmit: () -> Void
    @FocusState private var isPhysicalActivityFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()

            panel
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button("Done") {
                    isPhysicalActivityFocused = false
                }
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            Text("Active Break")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("Please complete the questions about the break you just finished.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.9))

            questionnaireList
                .frame(maxHeight: 460)

            submitButton
        }
        .padding(20)
        .background(Color.black.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.65), lineWidth: 1.5)
        )
        .padding(.horizontal, 18)
    }

    private var questionnaireList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if context.requiresPhysicalActivity {
                    physicalActivityField
                }

                if context.requiresInteractionPosture {
                    interactionPostureToggle
                }

                ForEach(PostBreakQuestionnaireCatalog.questionnaires, id: \.id) { questionnaire in
                    questionnaireSection(questionnaire)
                }
            }
        }
    }

    private var physicalActivityField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physical activity")
                .font(.headline)
                .foregroundColor(.white)

            TextEditor(text: $physicalActivity)
                .focused($isPhysicalActivityFocused)
                .frame(minHeight: 80)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var interactionPostureToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interaction posture")
                .font(.headline)
                .foregroundColor(.white)

            Toggle(isOn: $interactedStanding) {
                Text(interactedStanding ? "Standing" : "Seated")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }
            .toggleStyle(.switch)
            .padding(12)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var submitButton: some View {
        Button {
            isPhysicalActivityFocused = false
            onSubmit()
        } label: {
            Text("Submit")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(canSubmit ? Color.green.opacity(0.85) : Color.gray.opacity(0.6))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(!canSubmit)
    }

    private func questionnaireSection(_ questionnaire: PostBreakQuestionnaire) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(questionnaire.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(questionnaire.instruction)
                .font(.caption)
                .foregroundColor(.white.opacity(0.72))

            if questionnaire.items.isEmpty {
                Text("Questions will be added here.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.65))
            } else {
                ForEach(questionnaire.items, id: \.id) { item in
                    questionRow(item)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func questionRow(_ item: PostBreakQuestionnaireItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.prompt)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)

            Picker(item.prompt, selection: binding(for: item.id)) {
                ForEach(item.options, id: \.score) { option in
                    Text(option.label).tag(option.score)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var canSubmit: Bool {
        !context.requiresPhysicalActivity ||
        !physicalActivity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func binding(for itemId: String) -> Binding<Int> {
        Binding(
            get: { responses[itemId] ?? 0 },
            set: { responses[itemId] = $0 }
        )
    }
}

private enum PostBreakQuestionnaireCatalog {
    private static let vitalityOptions: [(score: Int, label: String)] = (1...7).map {
        ($0, "\($0)")
    }

    private static let pacesOptions: [(score: Int, label: String)] = (1...5).map {
        ($0, "\($0)")
    }

    static let questionnaires: [PostBreakQuestionnaire] = [
        PostBreakQuestionnaire(
            id: "subjective_vitality",
            title: "Vitality",
            instruction: "Please respond in terms of how you are feeling right now. 1 = Not at all true, 4 = Somewhat true, 7 = Very true.",
            items: [
                PostBreakQuestionnaireItem(
                    id: "vitality_alive_vital",
                    prompt: "At this moment, I feel alive and vital.",
                    options: vitalityOptions,
                    defaultScore: 4
                ),
                PostBreakQuestionnaireItem(
                    id: "vitality_not_energetic",
                    prompt: "I don't feel very energetic right now.",
                    options: vitalityOptions,
                    defaultScore: 4,
                    isReverseScored: true
                ),
                PostBreakQuestionnaireItem(
                    id: "vitality_burst",
                    prompt: "Currently I feel so alive I just want to burst.",
                    options: vitalityOptions,
                    defaultScore: 4
                ),
                PostBreakQuestionnaireItem(
                    id: "vitality_energy_spirit",
                    prompt: "At this time, I have energy and spirit.",
                    options: vitalityOptions,
                    defaultScore: 4
                ),
                PostBreakQuestionnaireItem(
                    id: "vitality_looking_forward",
                    prompt: "I am looking forward to each new day.",
                    options: vitalityOptions,
                    defaultScore: 4
                ),
                PostBreakQuestionnaireItem(
                    id: "vitality_alert_awake",
                    prompt: "At this moment, I feel alert and awake.",
                    options: vitalityOptions,
                    defaultScore: 4
                ),
                PostBreakQuestionnaireItem(
                    id: "vitality_energized",
                    prompt: "I feel energized right now.",
                    options: vitalityOptions,
                    defaultScore: 4
                )
            ]
        ),
        PostBreakQuestionnaire(
            id: "paces_s",
            title: "PACES-S",
            instruction: "When I think about this physical activity... 1 = Strongly Disagree, 2 = Disagree, 3 = Neutral, 4 = Agree, 5 = Strongly Agree.",
            items: [
                PostBreakQuestionnaireItem(
                    id: "paces_enjoy",
                    prompt: "I enjoy it.",
                    options: pacesOptions,
                    defaultScore: 3
                ),
                PostBreakQuestionnaireItem(
                    id: "paces_pleasurable",
                    prompt: "I find it pleasurable.",
                    options: pacesOptions,
                    defaultScore: 3
                ),
                PostBreakQuestionnaireItem(
                    id: "paces_pleasant",
                    prompt: "It is very pleasant.",
                    options: pacesOptions,
                    defaultScore: 3
                ),
                PostBreakQuestionnaireItem(
                    id: "paces_feels_good",
                    prompt: "It feels good.",
                    options: pacesOptions,
                    defaultScore: 3
                )
            ]
        )
    ]

    static var defaultResponses: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: questionnaires
                .flatMap(\.items)
                .map { ($0.id, $0.defaultScore) }
        )
    }

    static func recordedResponses(from responses: [String: Int]) -> [[String: Any]] {
        questionnaires.map { questionnaire in
            [
                "questionnaireId": questionnaire.id,
                "title": questionnaire.title,
                "instruction": questionnaire.instruction,
                "responses": Dictionary(
                    uniqueKeysWithValues: questionnaire.items.map { item in
                        (item.id, responses[item.id] ?? item.defaultScore)
                    }
                ),
                "items": questionnaire.items.map { item in
                    [
                        "itemId": item.id,
                        "prompt": item.prompt,
                        "response": responses[item.id] ?? item.defaultScore,
                        "isReverseScored": item.isReverseScored
                    ] as [String: Any]
                }
            ]
        }
    }
}

private struct PostBreakQuestionnaire {
    let id: String
    let title: String
    let instruction: String
    let items: [PostBreakQuestionnaireItem]
}

private struct PostBreakQuestionnaireItem {
    let id: String
    let prompt: String
    let options: [(score: Int, label: String)]
    let defaultScore: Int
    var isReverseScored = false
}
