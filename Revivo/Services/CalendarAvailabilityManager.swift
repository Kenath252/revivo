import EventKit
import Foundation

final class CalendarAvailabilityManager: ObservableObject {
    static let shared = CalendarAvailabilityManager()

    @Published private(set) var isInMeeting = false
    @Published private(set) var currentMeetingTitle: String?
    @Published private(set) var currentMeetingEndsAtS: Double?
    @Published private(set) var authorizationStatusDescription = "Not requested"

    private let eventStore = EKEventStore()
    private let pollIntervalSeconds: TimeInterval = 60
    private var pollTimer: Timer?
    private var lastRecordedState: Bool?

    private init() {}

    func startMonitoring() {
        requestCalendarAccessIfNeeded { [weak self] isGranted in
            guard let self else { return }
            DispatchQueue.main.async {
                guard isGranted else {
                    self.updateMeetingState(isInMeeting: false, event: nil)
                    return
                }

                self.refreshAvailability()
                self.startPollingIfNeeded()
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        updateMeetingState(isInMeeting: false, event: nil)
    }

    func refreshAvailability(referenceDate: Date = Date()) {
        let predicate = eventStore.predicateForEvents(
            withStart: referenceDate.addingTimeInterval(-1),
            end: referenceDate.addingTimeInterval(1),
            calendars: nil
        )

        let activeMeeting = eventStore.events(matching: predicate)
            .filter { event in
                event.startDate <= referenceDate &&
                event.endDate > referenceDate &&
                !event.isAllDay &&
                event.availability != .free &&
                event.status != .canceled &&
                eventAllowsInterruption(event) == false
            }
            .sorted { $0.endDate < $1.endDate }
            .first

        updateMeetingState(isInMeeting: activeMeeting != nil, event: activeMeeting)
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refreshAvailability()
        }
    }

    private func requestCalendarAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        updateAuthorizationDescription(status)

        switch status {
        case .fullAccess, .authorized:
            completion(true)
        case .notDetermined:
            if #available(iOS 17.0, *) {
                eventStore.requestFullAccessToEvents { [weak self] granted, _ in
                    self?.updateAuthorizationDescription(EKEventStore.authorizationStatus(for: .event))
                    completion(granted)
                }
            } else {
                eventStore.requestAccess(to: .event) { [weak self] granted, _ in
                    self?.updateAuthorizationDescription(EKEventStore.authorizationStatus(for: .event))
                    completion(granted)
                }
            }
        case .writeOnly, .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func updateMeetingState(isInMeeting: Bool, event: EKEvent?) {
        let title = event?.title
        let endsAtS = event?.endDate.timeIntervalSince1970

        self.isInMeeting = isInMeeting
        currentMeetingTitle = title
        currentMeetingEndsAtS = endsAtS

        if lastRecordedState != isInMeeting {
            lastRecordedState = isInMeeting
            DataRecordingManager.shared.recordCalendarAvailabilityEvent(
                isInMeeting: isInMeeting,
                meetingTitle: title,
                meetingEndsAtS: endsAtS
            )
            print("📅 Calendar availability changed: inMeeting=\(isInMeeting) title=\(title ?? "none")")
        }
    }

    private func updateAuthorizationDescription(_ status: EKAuthorizationStatus) {
        DispatchQueue.main.async {
            switch status {
            case .notDetermined:
                self.authorizationStatusDescription = "Not requested"
            case .restricted:
                self.authorizationStatusDescription = "Restricted"
            case .denied:
                self.authorizationStatusDescription = "Denied"
            case .authorized:
                self.authorizationStatusDescription = "Authorized"
            case .fullAccess:
                self.authorizationStatusDescription = "Full access"
            case .writeOnly:
                self.authorizationStatusDescription = "Write only"
            @unknown default:
                self.authorizationStatusDescription = "Unknown"
            }
        }
    }

    private func eventAllowsInterruption(_ event: EKEvent) -> Bool {
        let title = event.title?.lowercased() ?? ""
        return title.contains("focus time") || title.contains("available")
    }
}
