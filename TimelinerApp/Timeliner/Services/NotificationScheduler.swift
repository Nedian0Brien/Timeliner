import Foundation
import SwiftUI
import UserNotifications

/// Everything Timeliner asks iOS to say out loud.
///
/// Two kinds, and they answer different questions. A todo's own reminder answers "this
/// one, now"; the daily digest answers "what does today hold" once, at an hour you pick.
/// Neither is derived from the other, so both live here rather than one being a special
/// case of the other.
@MainActor
final class NotificationScheduler: NSObject, ObservableObject {
    static let shared = NotificationScheduler()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @AppStorage("dailyDigestEnabled") var digestEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }

    /// Minutes past midnight the digest is delivered at. 8:00 by default — early enough
    /// to change the day, late enough not to be the alarm clock.
    @AppStorage("dailyDigestMinutes") var digestMinutes: Int = 8 * 60 {
        didSet { objectWillChange.send() }
    }

    private let center = UNUserNotificationCenter.current()
    private let calendar = DateHelpers.calendar

    private static let todoPrefix = "todo."
    private static let schedulePrefix = "schedule."
    private static let digestPrefix = "digest."
    /// How far ahead digests are laid down.
    ///
    /// A repeating trigger would be one request instead of seven, but its body is fixed
    /// at scheduling time and the whole point of this notification is the count in it.
    /// So each day gets its own request, written with that day's numbers, and the run is
    /// rebuilt whenever the data changes.
    private static let digestHorizonDays = 7

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private override init() {
        super.init()
        // Without a delegate iOS drops a notification whose app is already frontmost.
        // That is the right default for most apps and the wrong one here: a todo's alarm
        // is about the todo, not about whether you happen to be looking at the app.
        center.delegate = self
    }

    // MARK: - Permission

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// Returns whether notifications may now be posted, asking only if iOS has not
    /// already been asked — a second request never shows a prompt, it just returns.
    @discardableResult
    func requestAuthorization() async -> Bool {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return isAuthorized }

        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A refusal is not an error worth surfacing: the status below says the same
            // thing, and the settings screen already reads it.
        }
        await refreshAuthorizationStatus()
        return isAuthorized
    }

    // MARK: - Syncing

    /// Rewrites every notification this app owns from the data as it now stands.
    ///
    /// A wholesale rewrite rather than a diff. The set is small, the work is off the main
    /// actor's critical path, and a diff would have to track deletions of rows that are
    /// already gone from the store — the one case that leaves a notification firing for
    /// something that no longer exists.
    func sync(todos: [TodoItem], schedules: [Schedule]) async {
        await refreshAuthorizationStatus()
        guard isAuthorized else {
            center.removeAllPendingNotificationRequests()
            return
        }

        let pending = await center.pendingNotificationRequests()
        let ours = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.todoPrefix) || $0.hasPrefix(Self.schedulePrefix) || $0.hasPrefix(Self.digestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        await scheduleTodoReminders(todos)
        await scheduleScheduleAlarms(schedules)
        await scheduleDigests(todos: todos, schedules: schedules)
    }

    private func scheduleScheduleAlarms(_ schedules: [Schedule]) async {
        let now = Date()

        for schedule in schedules {
            // An event exported to Apple 캘린더 carries its own alarm over there, and
            // EventKit will raise it. Firing here too would say the same thing twice.
            guard schedule.calendarEventIdentifier == nil,
                  let fireAt = schedule.alarmMoment, fireAt > now
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = schedule.text
            content.body = alarmBody(for: schedule)
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            let request = UNNotificationRequest(
                identifier: Self.schedulePrefix + schedule.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func alarmBody(for schedule: Schedule) -> String {
        var parts: [String] = []
        if schedule.isAllDay {
            parts.append("종일")
        } else if let startText = schedule.startText {
            parts.append(startText)
        }
        if let location = schedule.locationText, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    private func scheduleTodoReminders(_ todos: [TodoItem]) async {
        let now = Date()

        for todo in todos {
            // A moment already past cannot be delivered, and a finished item has nothing
            // left to say.
            guard let fireAt = todo.reminderAt, fireAt > now, !todo.completed else { continue }

            let content = UNMutableNotificationContent()
            content.title = "할 일"
            content.body = todo.text
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            let request = UNNotificationRequest(
                identifier: Self.todoPrefix + todo.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func scheduleDigests(todos: [TodoItem], schedules: [Schedule]) async {
        guard digestEnabled else { return }

        let now = Date()
        let today = DateHelpers.startOfDay(now)

        for offset in 0..<Self.digestHorizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fireAt = calendar.date(byAdding: .minute, value: digestMinutes, to: day),
                  fireAt > now
            else { continue }

            let dayTodos = todos.filter { DateHelpers.sameDay($0.date, day) && !$0.completed }
            let daySchedules = schedules.filter { DateHelpers.sameDay($0.date, day) }
            // Nothing to report is not worth a notification. Saying "0개" every morning
            // is how a digest teaches people to swipe it away unread.
            guard !dayTodos.isEmpty || !daySchedules.isEmpty else { continue }

            let content = UNMutableNotificationContent()
            content.title = DateHelpers.koreanDateLabel(day)
            content.body = digestBody(todoCount: dayTodos.count, scheduleCount: daySchedules.count)
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            let request = UNNotificationRequest(
                identifier: Self.digestPrefix + Self.dayKey(day),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func digestBody(todoCount: Int, scheduleCount: Int) -> String {
        var parts: [String] = []
        if scheduleCount > 0 { parts.append("일정 \(scheduleCount)개") }
        if todoCount > 0 { parts.append("할 일 \(todoCount)개") }
        return parts.joined(separator: ", ") + "가 있습니다."
    }

    private static func dayKey(_ day: Date) -> String {
        let components = DateHelpers.calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension NotificationScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
