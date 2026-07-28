import Foundation
import SwiftData

enum ScheduleColorTheme: String, Codable, CaseIterable {
    case emerald, orange, blue, purple, gray

    var iconCandidate: String { rawValue }
}

@Model
final class Schedule {
    @Attribute(.unique) var id: UUID = UUID()
    /// Which day this belongs to, as a start of day.
    ///
    /// Kept alongside `startAt` rather than derived from it, because an all-day event has
    /// no `startAt` to derive it from, and the timeline groups by day before it sorts by
    /// anything.
    var date: Date = Date()
    /// The moment it begins, or `nil` when it takes the whole day.
    ///
    /// This used to be a `"09:30 AM"` string. A string cannot be compared across a day
    /// boundary, cannot represent an event that ends after midnight, silently became
    /// midnight when it failed to parse, and had no time zone — so every hour it held was
    /// a label rather than a moment.
    var startAt: Date? = nil
    /// The moment it ends. `nil` means nobody wrote one down, not that it never ends.
    var endAt: Date? = nil
    var text: String = ""
    var calendarName: String? = nil
    var locationText: String? = nil
    var colorThemeRaw: String = ScheduleColorTheme.blue.rawValue
    var iconName: String = "calendar"
    var calendarEventIdentifier: String? = nil
    var createdAt: Date = Date()

    /// Takes the whole day, with no hour of its own.
    ///
    /// A flag rather than the absence of `startAt`, because those are different things:
    /// an all-day event genuinely has no hour, while a schedule that is merely missing one
    /// is an event someone has not finished writing down.
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
        startAt: Date? = nil,
        endAt: Date? = nil,
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
        self.startAt = startAt
        self.endAt = endAt
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

    // MARK: - Reading the hour

    /// Minutes past midnight of `date`, for ordering rows inside one day.
    ///
    /// The timeline sorts a day's rows against each other, and inside a day this is the
    /// same ordering as the moments themselves. Anything comparing across days should
    /// use `startAt` directly, which is the whole reason it is a `Date` now.
    var startMinutes: Int? {
        startAt.map(DateHelpers.minutesSinceMidnight(from:))
    }

    var endMinutes: Int? {
        endAt.map(DateHelpers.minutesSinceMidnight(from:))
    }

    /// "09:30", or `nil` when there is no hour to show.
    var startText: String? {
        startAt.map(DateHelpers.format24Hour(from:))
    }

    var endText: String? {
        endAt.map(DateHelpers.format24Hour(from:))
    }

    /// When the alarm for this schedule should fire, if it has one.
    ///
    /// An all-day event has no start to count back from, so its alarm is pinned to 9 in
    /// the morning — the same hour a todo's first alarm lands on, for the same reason.
    var alarmMoment: Date? {
        guard let alarmMinutesBefore else { return nil }
        guard let anchor = startAt ?? DateHelpers.calendar.date(
            bySettingHour: 9, minute: 0, second: 0, of: DateHelpers.startOfDay(date)
        ) else { return nil }
        return DateHelpers.calendar.date(byAdding: .minute, value: -alarmMinutesBefore, to: anchor)
    }
}

extension Schedule: Identifiable {}
