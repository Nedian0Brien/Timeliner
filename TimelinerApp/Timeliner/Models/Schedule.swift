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
        createdAt: Date = Date()
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
    }
}

extension Schedule: Identifiable {}
