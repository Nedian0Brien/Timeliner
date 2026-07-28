import EventKit
import Foundation
import UIKit

struct EventKitImportResult {
    let insertedSchedules: [Schedule]
    let insertedTodos: [TodoItem]
    let deletedSchedules: [Schedule]
    let deletedTodos: [TodoItem]
    let updatedScheduleCount: Int
    let updatedTodoCount: Int
    let skippedDatelessReminderCount: Int

    var importedScheduleCount: Int { insertedSchedules.count + updatedScheduleCount }
    var importedTodoCount: Int { insertedTodos.count + updatedTodoCount }
    var deletedCount: Int { deletedSchedules.count + deletedTodos.count }
}

@MainActor
final class EventKitSyncManager: ObservableObject {
    static let shared = EventKitSyncManager()

    @Published private(set) var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var isSyncing: Bool = false
    @Published var statusMessage: String?

    private let eventStore = EKEventStore()
    private let calendar = DateHelpers.calendar

    var canSyncCalendar: Bool {
        isAuthorized(calendarStatus)
    }

    var canSyncReminders: Bool {
        isAuthorized(reminderStatus)
    }

    var canSyncAnySource: Bool {
        canSyncCalendar || canSyncReminders
    }

    var permissionSummary: String {
        "캘린더 \(label(for: calendarStatus, entityType: .event)) · 미리알림 \(label(for: reminderStatus, entityType: .reminder))"
    }

    private init() {}

    func refreshAuthorizationStatus() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    func importItems(
        from startDate: Date,
        to endDate: Date,
        existingSchedules: [Schedule],
        existingTodos: [TodoItem]
    ) async -> EventKitImportResult? {
        guard !isSyncing else { return nil }

        isSyncing = true
        defer { isSyncing = false }

        let normalizedStart = DateHelpers.startOfDay(startDate)
        let normalizedEnd = max(endDate, normalizedStart.addingTimeInterval(60))
        var insertedSchedules: [Schedule] = []
        var insertedTodos: [TodoItem] = []
        var deletedSchedules: [Schedule] = []
        var deletedTodos: [TodoItem] = []
        var updatedScheduleCount = 0
        var updatedTodoCount = 0
        var skippedDatelessReminderCount = 0
        var importedSources: [String] = []
        var blockedSources: [String] = []

        refreshAuthorizationStatus()

        do {
            if await ensureCalendarAccess() {
                let eventResult = importEvents(
                    from: normalizedStart,
                    to: normalizedEnd,
                    existingSchedules: existingSchedules
                )
                insertedSchedules = eventResult.inserted
                deletedSchedules = eventResult.deleted
                updatedScheduleCount = eventResult.updated
                importedSources.append("캘린더")
            } else {
                blockedSources.append("캘린더")
            }

            if await ensureReminderAccess() {
                let reminderResult = try await importReminders(
                    from: normalizedStart,
                    to: normalizedEnd,
                    existingTodos: existingTodos
                )
                insertedTodos = reminderResult.inserted
                deletedTodos = reminderResult.deleted
                updatedTodoCount = reminderResult.updated
                skippedDatelessReminderCount = reminderResult.skippedDateless
                importedSources.append("미리알림")
            } else {
                blockedSources.append("미리알림")
            }
        } catch {
            statusMessage = error.localizedDescription
            refreshAuthorizationStatus()
            return nil
        }

        guard !importedSources.isEmpty else {
            statusMessage = "가져오려면 캘린더 또는 미리알림 접근 권한이 필요합니다."
            return nil
        }

        let result = EventKitImportResult(
            insertedSchedules: insertedSchedules,
            insertedTodos: insertedTodos,
            deletedSchedules: deletedSchedules,
            deletedTodos: deletedTodos,
            updatedScheduleCount: updatedScheduleCount,
            updatedTodoCount: updatedTodoCount,
            skippedDatelessReminderCount: skippedDatelessReminderCount
        )

        statusMessage = importSummary(for: result, importedSources: importedSources, blockedSources: blockedSources)
        return result
    }

    func setReminderCompleted(identifier: String, completed: Bool) async -> Bool {
        guard await ensureReminderAccess() else { return false }
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            statusMessage = "Apple 미리알림에서 항목을 찾을 수 없습니다. 다시 가져오기를 실행하세요."
            return false
        }

        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil

        do {
            try eventStore.save(reminder, commit: true)
            statusMessage = nil
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// The 미리알림 lists a todo can actually be written into.
    ///
    /// Read-only lists — a shared list someone else owns, a subscribed one — come back
    /// from EventKit like any other and then reject the save, so offering them would be
    /// offering a failure.
    func reminderLists() async -> [EKCalendar] {
        guard await ensureReminderAccess() else { return [] }
        return eventStore.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func defaultReminderListIdentifier() async -> String? {
        guard await ensureReminderAccess() else { return nil }
        return eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    /// Writes a todo out to Apple 미리알림, creating the reminder or updating the one it
    /// is already linked to.
    ///
    /// Returns the item identifier so the caller can hold on to it. That handle is the
    /// only thing joining the two copies; losing it turns the next save into a second
    /// reminder rather than an edit of the first.
    ///
    /// Only the fields Timeliner actually models are written. A reminder's alarms, notes,
    /// priority, subtasks and recurrence belong to whoever set them — most often the
    /// 미리알림 app — and saving a whole reminder built from a todo would erase every one
    /// of them. Alarms in particular are left alone on purpose: `reminderAt` already
    /// raises Timeliner's own notification, and adding an `EKAlarm` beside it would ring
    /// the same todo twice on the same phone.
    func exportReminder(
        title: String,
        day: Date,
        listIdentifier: String?,
        existingIdentifier: String?
    ) async -> String? {
        guard await ensureReminderAccess() else { return nil }

        let reminder: EKReminder
        if let existingIdentifier,
           let found = eventStore.calendarItem(withIdentifier: existingIdentifier) as? EKReminder {
            reminder = found
        } else {
            reminder = EKReminder(eventStore: eventStore)
        }

        guard let list = targetReminderList(for: listIdentifier, current: reminder.calendar) else {
            statusMessage = "쓸 수 있는 미리알림 목록을 찾지 못했습니다."
            return nil
        }
        // Assigned unconditionally rather than only when it differs: for a reminder that
        // does not exist yet there is nothing to differ from, and for one that does,
        // writing the same list back is a no-op.
        reminder.calendar = list
        reminder.title = title
        // Day-only, to match what a todo actually carries. Keeping the hour would invent
        // a time the user was never shown and had no way to set.
        reminder.dueDateComponents = calendar.dateComponents(
            [.year, .month, .day],
            from: DateHelpers.startOfDay(day)
        )

        do {
            try eventStore.save(reminder, commit: true)
            statusMessage = nil
            return reminder.calendarItemIdentifier
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    /// Removes the Apple 미리알림 copy of a todo. Silent when there is nothing to remove:
    /// a reminder already deleted over there is the state this was asking for.
    @discardableResult
    func deleteExportedReminder(identifier: String) async -> Bool {
        guard await ensureReminderAccess() else { return false }
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return true
        }

        do {
            try eventStore.remove(reminder, commit: true)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// The calendars an event can actually be written into.
    ///
    /// Subscribed and delivered calendars come back from EventKit like any other but
    /// reject writes, so offering them would be offering a save that fails.
    func writableCalendars() async -> [EKCalendar] {
        guard await ensureCalendarAccess() else { return [] }
        return eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func defaultCalendarIdentifier() async -> String? {
        guard await ensureCalendarAccess() else { return nil }
        return eventStore.defaultCalendarForNewEvents?.calendarIdentifier
    }

    /// Writes a schedule out to Apple 캘린더, creating the event or updating the one it
    /// already came from.
    ///
    /// Returns the event identifier so the caller can hold on to it — that handle is the
    /// only thing linking the two copies, and losing it turns the next export into a
    /// duplicate rather than an edit.
    func exportEvent(
        title: String,
        isAllDay: Bool,
        day: Date,
        start: Date?,
        end: Date?,
        location: String?,
        notes: String?,
        url: URL?,
        alarmMinutesBefore: Int?,
        calendarIdentifier: String?,
        existingEventIdentifier: String?
    ) async -> String? {
        guard await ensureCalendarAccess() else { return nil }

        let event: EKEvent
        // `event(withIdentifier:)`, not `calendarItem(withIdentifier:)`: an event carries
        // two identifiers and they are not interchangeable. The importer files a schedule
        // under `eventIdentifier`, so that is what comes back here, and looking it up as a
        // calendar item finds nothing — which would quietly make every save a brand new
        // event instead of an edit of the one already there.
        if let existingEventIdentifier,
           let found = eventStore.event(withIdentifier: existingEventIdentifier) {
            event = found
        } else {
            event = EKEvent(eventStore: eventStore)
        }

        guard let calendar = targetCalendar(for: calendarIdentifier, current: event.calendar) else {
            statusMessage = "쓸 수 있는 캘린더를 찾지 못했습니다."
            return nil
        }
        event.calendar = calendar
        event.title = title
        event.location = location
        event.notes = notes
        event.url = url
        event.isAllDay = isAllDay

        if isAllDay {
            let startOfDay = DateHelpers.startOfDay(day)
            event.startDate = startOfDay
            event.endDate = startOfDay
        } else {
            let startDate = start ?? DateHelpers.startOfDay(day)
            event.startDate = startDate
            // EventKit rejects an end that is not after the start, and a schedule with no
            // end written down is a schedule someone means to last an hour.
            event.endDate = max(end ?? startDate.addingTimeInterval(3600),
                                startDate.addingTimeInterval(60))
        }

        // Replaced rather than added to: leaving the old ones would stack a new alarm on
        // every save.
        for alarm in event.alarms ?? [] { event.removeAlarm(alarm) }
        if let alarmMinutesBefore {
            event.addAlarm(EKAlarm(relativeOffset: -Double(alarmMinutesBefore) * 60))
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            statusMessage = nil
            // The same identifier the importer keys on, so the next import recognises
            // this event as one it already has rather than importing a duplicate.
            return event.eventIdentifier
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    /// Removes the Apple 캘린더 copy of a schedule. Silent when there is nothing to remove.
    @discardableResult
    func deleteExportedEvent(identifier: String) async -> Bool {
        guard await ensureCalendarAccess() else { return false }
        guard let event = eventStore.event(withIdentifier: identifier) else {
            return true
        }

        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// Where a reminder should be written: the list asked for, else the one it already
    /// sits in, else whatever 미리알림 itself would have picked.
    private func targetReminderList(for identifier: String?, current: EKCalendar?) -> EKCalendar? {
        if let identifier,
           let match = eventStore.calendar(withIdentifier: identifier),
           match.allowsContentModifications {
            return match
        }
        if let current, current.allowsContentModifications { return current }
        return eventStore.defaultCalendarForNewReminders()
            ?? eventStore.calendars(for: .reminder).first(where: \.allowsContentModifications)
    }

    private func targetCalendar(for identifier: String?, current: EKCalendar?) -> EKCalendar? {
        if let identifier,
           let match = eventStore.calendar(withIdentifier: identifier),
           match.allowsContentModifications {
            return match
        }
        if let current, current.allowsContentModifications { return current }
        return eventStore.defaultCalendarForNewEvents
            ?? eventStore.calendars(for: .event).first(where: \.allowsContentModifications)
    }

    private func ensureCalendarAccess() async -> Bool {
        refreshAuthorizationStatus()
        if canSyncCalendar { return true }
        guard calendarStatus == .notDetermined else { return false }

        do {
            let granted = try await requestCalendarAccess()
            calendarStatus = EKEventStore.authorizationStatus(for: .event)
            return granted || canSyncCalendar
        } catch {
            statusMessage = error.localizedDescription
            refreshAuthorizationStatus()
            return false
        }
    }

    private func ensureReminderAccess() async -> Bool {
        refreshAuthorizationStatus()
        if canSyncReminders { return true }
        guard reminderStatus == .notDetermined else { return false }

        do {
            let granted = try await requestReminderAccess()
            reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
            return granted || canSyncReminders
        } catch {
            statusMessage = error.localizedDescription
            refreshAuthorizationStatus()
            return false
        }
    }

    private func requestCalendarAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    private func requestReminderAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    private func importEvents(
        from startDate: Date,
        to endDate: Date,
        existingSchedules: [Schedule]
    ) -> (inserted: [Schedule], deleted: [Schedule], updated: Int) {
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate)
        var schedulesByIdentifier = Dictionary(uniqueKeysWithValues: existingSchedules.compactMap { schedule in
            schedule.calendarEventIdentifier.map { ($0, schedule) }
        })
        var seenIdentifiers: Set<String> = []
        var inserted: [Schedule] = []
        var updated = 0

        for event in events where !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let identifier = event.eventIdentifier else { continue }
            seenIdentifiers.insert(identifier)

            if let schedule = schedulesByIdentifier[identifier] {
                update(schedule, with: event)
                updated += 1
            } else {
                let schedule = makeSchedule(from: event, identifier: identifier)
                schedulesByIdentifier[identifier] = schedule
                inserted.append(schedule)
            }
        }

        let deleted = existingSchedules.filter { schedule in
            guard let identifier = schedule.calendarEventIdentifier else { return false }
            return schedule.date >= startDate && schedule.date < endDate && !seenIdentifiers.contains(identifier)
        }

        return (inserted, deleted, updated)
    }

    private func importReminders(
        from startDate: Date,
        to endDate: Date,
        existingTodos: [TodoItem]
    ) async throws -> (inserted: [TodoItem], deleted: [TodoItem], updated: Int, skippedDateless: Int) {
        let reminders = await reminders(from: startDate, to: endDate)
        var todosByIdentifier = Dictionary(uniqueKeysWithValues: existingTodos.compactMap { todo in
            todo.reminderIdentifier.map { ($0, todo) }
        })
        var nextSortOrderByDay = nextSortOrdersByDay(existingTodos)
        var seenIdentifiers: Set<String> = []
        var inserted: [TodoItem] = []
        var updated = 0
        var skippedDateless = 0

        for reminder in reminders where !reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let dueDate = reminder.timelinerDueDate(calendar: calendar) else {
                skippedDateless += 1
                continue
            }
            guard dueDate >= startDate, dueDate < endDate else { continue }

            let identifier = reminder.calendarItemIdentifier
            seenIdentifiers.insert(identifier)

            if let todo = todosByIdentifier[identifier] {
                update(todo, with: reminder, dueDate: dueDate)
                updated += 1
            } else {
                let day = DateHelpers.startOfDay(dueDate)
                let sortOrder = nextSortOrderByDay[day, default: 0]
                nextSortOrderByDay[day] = sortOrder + 1
                let todo = makeTodo(from: reminder, dueDate: dueDate, sortOrder: sortOrder)
                todosByIdentifier[identifier] = todo
                inserted.append(todo)
            }
        }

        let deleted = existingTodos.filter { todo in
            guard let identifier = todo.reminderIdentifier else { return false }
            return todo.date >= startDate && todo.date < endDate && !seenIdentifiers.contains(identifier)
        }

        return (inserted, deleted, updated, skippedDateless)
    }

    private func makeSchedule(from event: EKEvent, identifier: String) -> Schedule {
        Schedule(
            date: DateHelpers.startOfDay(event.startDate),
            startAt: event.isAllDay ? nil : event.startDate,
            endAt: event.isAllDay ? nil : event.endDate,
            text: event.title,
            calendarName: event.calendar?.title,
            locationText: event.location,
            colorTheme: colorTheme(for: event),
            iconName: "calendar",
            calendarEventIdentifier: identifier,
            createdAt: Date()
        )
    }

    private func update(_ schedule: Schedule, with event: EKEvent) {
        schedule.date = DateHelpers.startOfDay(event.startDate)
        schedule.startAt = event.isAllDay ? nil : event.startDate
        schedule.endAt = event.isAllDay ? nil : event.endDate
        schedule.text = event.title
        schedule.calendarName = event.calendar?.title
        schedule.locationText = event.location
        schedule.colorTheme = colorTheme(for: event)
        schedule.iconName = "calendar"
    }

    private func makeTodo(from reminder: EKReminder, dueDate: Date, sortOrder: Int) -> TodoItem {
        TodoItem(
            date: DateHelpers.startOfDay(dueDate),
            text: reminder.title,
            completed: reminder.isCompleted,
            sortOrder: sortOrder,
            reminderIdentifier: reminder.calendarItemIdentifier,
            reminderListIdentifier: reminder.calendar?.calendarIdentifier,
            createdAt: Date()
        )
    }

    private func update(_ todo: TodoItem, with reminder: EKReminder, dueDate: Date) {
        todo.date = DateHelpers.startOfDay(dueDate)
        todo.text = reminder.title
        // Followed rather than fixed at import: a todo moved to another list in 미리알림
        // should open on the list it is actually in, not the one it started in.
        todo.reminderListIdentifier = reminder.calendar?.calendarIdentifier
        // Reminders carries its own completion date; fall back to now only when it is
        // newly completed here and EventKit has not supplied one.
        if todo.completed != reminder.isCompleted {
            todo.completedAt = reminder.isCompleted ? (reminder.completionDate ?? Date()) : nil
        }
        todo.completed = reminder.isCompleted
    }

    private func nextSortOrdersByDay(_ todos: [TodoItem]) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for todo in todos {
            let day = DateHelpers.startOfDay(todo.date)
            result[day] = max(result[day, default: 0], todo.sortOrder + 1)
        }
        return result
    }

    private func reminders(from startDate: Date, to endDate: Date) async -> [EKReminder] {
        async let incomplete = fetchReminders(
            matching: eventStore.predicateForIncompleteReminders(
                withDueDateStarting: startDate,
                ending: endDate,
                calendars: nil
            )
        )
        async let completed = fetchReminders(
            matching: eventStore.predicateForCompletedReminders(
                withCompletionDateStarting: startDate,
                ending: endDate,
                calendars: nil
            )
        )

        let merged = await incomplete + completed
        var seen: Set<String> = []
        return merged.filter { reminder in
            seen.insert(reminder.calendarItemIdentifier).inserted
        }
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func colorTheme(for event: EKEvent) -> ScheduleColorTheme {
        guard let cgColor = event.calendar?.cgColor else { return .blue }

        let color = UIColor(cgColor: cgColor)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return .blue
        }

        guard saturation >= 0.18, brightness >= 0.18 else { return .gray }

        switch hue {
        case 0.06..<0.16:
            return .orange
        case 0.22..<0.47:
            return .emerald
        case 0.47..<0.68:
            return .blue
        case 0.68..<0.86:
            return .purple
        default:
            return .orange
        }
    }

    private func importSummary(
        for result: EventKitImportResult,
        importedSources: [String],
        blockedSources: [String]
    ) -> String {
        var parts = [
            "캘린더 \(result.importedScheduleCount)개",
            "미리알림 \(result.importedTodoCount)개"
        ]
        if result.deletedCount > 0 {
            parts.append("삭제 반영 \(result.deletedCount)개")
        }
        if result.skippedDatelessReminderCount > 0 {
            parts.append("날짜 없는 미리알림 제외 \(result.skippedDatelessReminderCount)개")
        }
        if !blockedSources.isEmpty {
            parts.append("권한 없음: \(blockedSources.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    private func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    private func label(for status: EKAuthorizationStatus, entityType: EKEntityType) -> String {
        switch status {
        case .notDetermined:
            return "대기"
        case .restricted:
            return "제한됨"
        case .denied:
            return "거부됨"
        case .authorized:
            return "허용됨"
        case .fullAccess:
            return "허용됨"
        case .writeOnly:
            return entityType == .event ? "쓰기 전용" : "제한됨"
        @unknown default:
            return "알 수 없음"
        }
    }
}

private extension EKReminder {
    func timelinerDueDate(calendar: Calendar) -> Date? {
        if let dueDateComponents,
           let dueDate = calendar.date(from: dueDateComponents) {
            return DateHelpers.startOfDay(dueDate)
        }

        if let startDateComponents,
           let startDate = calendar.date(from: startDateComponents) {
            return DateHelpers.startOfDay(startDate)
        }

        return nil
    }
}
