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

    /// "06:30 AM" from "HH:mm"
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

    /// "HH:mm" of current time
    static func currentHHmm() -> String {
        let now = Date()
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    /// "06:30 AM" of current time
    static func currentTime12() -> String {
        format12Hour(fromHHmm: currentHHmm())
    }

    static func format24Hour(from storedTime: String) -> String {
        let minutes = minutesSinceMidnight(from: storedTime)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func addingMinutes(_ minutes: Int, to storedTime: String) -> String {
        let total = (minutesSinceMidnight(from: storedTime) + minutes + 1440) % 1440
        return format12Hour(fromHHmm: String(format: "%02d:%02d", total / 60, total % 60))
    }

    /// Returns minutes since midnight for either a 12-hour or 24-hour time string.
    static func minutesSinceMidnight(from time12: String) -> Int {
        let pieces = time12.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        if pieces.count == 1 {
            let timePieces = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
            guard timePieces.count == 2,
                  let hour = Int(timePieces[0]),
                  let minute = Int(timePieces[1]),
                  (0..<24).contains(hour),
                  (0..<60).contains(minute) else { return 0 }
            return hour * 60 + minute
        }

        guard pieces.count == 2 else { return 0 }

        let timePieces = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
        guard timePieces.count == 2,
              var hour = Int(timePieces[0]),
              let minute = Int(timePieces[1]) else { return 0 }

        let ampm = pieces[1].uppercased()
        guard ampm == "AM" || ampm == "PM" else { return 0 }

        if ampm == "PM" && hour < 12 { hour += 12 }
        if ampm == "AM" && hour == 12 { hour = 0 }
        return hour * 60 + minute
    }

    /// "09:05" from a date. The stored-string helpers above can't serve todos, which
    /// carry real timestamps rather than a time field.
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
