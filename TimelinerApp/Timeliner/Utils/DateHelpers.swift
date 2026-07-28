import Foundation

enum DateHelpers {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// "4월 19일"
    static func koreanDateLabel(_ date: Date) -> String {
        let comps = calendar.dateComponents([.month, .day], from: date)
        return "\(comps.month ?? 0)월 \(comps.day ?? 0)일"
    }

    /// "7/16"
    static func slashDateLabel(_ date: Date) -> String {
        let comps = calendar.dateComponents([.month, .day], from: date)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }

    /// "토"
    static func koreanDayLabel(_ date: Date) -> String {
        let days = ["일", "월", "화", "수", "목", "금", "토"]
        let idx = calendar.component(.weekday, from: date) - 1
        return days[(idx + 7) % 7]
    }

    /// "2026년 4월"
    static func koreanMonthLabel(_ date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return "\(comps.year ?? 0)년 \(comps.month ?? 0)월"
    }

    /// The moment `hour:minute` falls on `day`.
    ///
    /// Returns `day` itself if the calendar cannot build it — which happens at a DST
    /// spring-forward, where the hour genuinely does not exist. Midnight of the right day
    /// is a better answer there than a `nil` every caller would have to invent one for.
    static func moment(hour: Int, minute: Int, on day: Date) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay(day))
            ?? startOfDay(day)
    }

    /// The moment `"09:30"` falls on `day`.
    static func moment(hhmm: String, on day: Date) -> Date {
        let pieces = hhmm.split(separator: ":")
        let hour = pieces.count == 2 ? Int(pieces[0]) ?? 0 : 0
        let minute = pieces.count == 2 ? Int(pieces[1]) ?? 0 : 0
        return moment(hour: hour, minute: minute, on: day)
    }

    static func format12Hour(fromHHmm input: String) -> String {
        let parts = input.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return input }
        let ampm = h >= 12 ? "PM" : "AM"
        var hour12 = h % 12
        if hour12 == 0 { hour12 = 12 }
        return String(format: "%02d:%02d %@", hour12, m, ampm)
    }

    /// "09:05" from a date.
    static func format24Hour(from date: Date) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    static func minutesSinceMidnight(from date: Date) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// "1시간 30분". Drops the empty half rather than saying "1시간 0분".
    static func koreanDuration(minutes: Int) -> String {
        let total = max(0, minutes)
        let hours = total / 60
        let remainder = total % 60
        switch (hours, remainder) {
        case (0, _): return "\(remainder)분"
        case (_, 0): return "\(hours)시간"
        default: return "\(hours)시간 \(remainder)분"
        }
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }
}
