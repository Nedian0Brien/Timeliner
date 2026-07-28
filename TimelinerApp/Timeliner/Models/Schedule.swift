import Foundation
import SwiftData

enum ScheduleColorTheme: String, Codable, CaseIterable {
    case emerald, orange, blue, purple, gray

    var iconCandidate: String { rawValue }
}

@Model
final class Schedule {
    @Attribute(.unique) var id: UUID = UUID()
    var date: Date = Date()
    var timeString: String? = nil
    var endTimeString: String? = nil
    var text: String = ""
    var calendarName: String? = nil
    var locationText: String? = nil
    var colorThemeRaw: String = ScheduleColorTheme.blue.rawValue
    var iconName: String = "calendar"
    var calendarEventIdentifier: String? = nil
    var createdAt: Date = Date()

    /// Takes the whole day, with no hour of its own.
    ///
    /// A flag rather than the absence of `timeString`, because those are different
    /// things: an all-day event genuinely has no hour, while a schedule that is merely
    /// missing one is an event someone has not finished writing down.
    var isAllDay: Bool = false
    var notes: String? = nil
    /// Kept as a string, which is what a user types and what EventKit hands back. It is
    /// parsed into a `URL` only where one is needed, so a half-typed address is a thing
    /// the field can hold rather than something the model refuses.
    var urlString: String? = nil
    /// Minutes before the start to raise a notification, or `nil` for none. `0` means at
    /// the start itself, which is why this cannot be folded into "non-zero means on".
    var alarmMinutesBefore: Int? = nil
    /// Which calendar this belongs in, by `EKCalendar.calendarIdentifier`.
    ///
    /// Separate from `calendarName`: the name is what gets drawn on the card and survives
    /// the calendar being renamed or unavailable, while this is the handle EventKit needs
    /// in order to write the event back.
    var calendarIdentifier: String? = nil

    var colorTheme: ScheduleColorTheme {
        get { ScheduleColorTheme(rawValue: colorThemeRaw) ?? .blue }
        set { colorThemeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        date: Date,
        timeString: String? = nil,
        endTimeString: String? = nil,
        text: String,
        calendarName: String? = nil,
        locationText: String? = nil,
        colorTheme: ScheduleColorTheme = .blue,
        iconName: String = "calendar",
        calendarEventIdentifier: String? = nil,
        createdAt: Date = Date(),
        isAllDay: Bool = false,
        notes: String? = nil,
        urlString: String? = nil,
        alarmMinutesBefore: Int? = nil,
        calendarIdentifier: String? = nil
    ) {
        self.id = id
        self.date = date
        self.timeString = timeString
        self.endTimeString = endTimeString
        self.text = text
        self.calendarName = calendarName
        self.locationText = locationText
        self.colorThemeRaw = colorTheme.rawValue
        self.iconName = iconName
        self.calendarEventIdentifier = calendarEventIdentifier
        self.createdAt = createdAt
        self.isAllDay = isAllDay
        self.notes = notes
        self.urlString = urlString
        self.alarmMinutesBefore = alarmMinutesBefore
        self.calendarIdentifier = calendarIdentifier
    }

    /// The moment the schedule starts, or `nil` when it has no hour of its own.
    var startMoment: Date? {
        guard !isAllDay, let timeString else { return nil }
        let minutes = DateHelpers.minutesSinceMidnight(from: timeString)
        return DateHelpers.calendar.date(
            byAdding: .minute, value: minutes, to: DateHelpers.startOfDay(date)
        )
    }

    var endMoment: Date? {
        guard !isAllDay, let endTimeString else { return nil }
        let minutes = DateHelpers.minutesSinceMidnight(from: endTimeString)
        return DateHelpers.calendar.date(
            byAdding: .minute, value: minutes, to: DateHelpers.startOfDay(date)
        )
    }

    /// When the alarm for this schedule should fire, if it has one.
    ///
    /// An all-day event has no start to count back from, so its alarm is pinned to 9 in
    /// the morning — the same hour a todo's first alarm lands on, for the same reason.
    var alarmMoment: Date? {
        guard let alarmMinutesBefore else { return nil }
        guard let anchor = startMoment ?? DateHelpers.calendar.date(
            bySettingHour: 9, minute: 0, second: 0, of: DateHelpers.startOfDay(date)
        ) else { return nil }
        return DateHelpers.calendar.date(byAdding: .minute, value: -alarmMinutesBefore, to: anchor)
    }
}

extension Schedule: Identifiable {}
