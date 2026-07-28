import SwiftUI
import SwiftData
import Charts

enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var label: String { self == .week ? "이번 주" : "이번 달" }
}

/// The insight cards, without a screen around them.
///
/// They used to be a tab of their own. As a section under the calendar's agenda they
/// answer the question the calendar raises — you have just looked at a month, and this
/// is what the month came to — instead of asking you to go and find them.
struct StatisticsSection: View {
    @Environment(\.colorScheme) private var scheme
    @Query private var schedules: [Schedule]
    @Query private var records: [Record]
    @Query private var todos: [TodoItem]

    @State private var period: StatsPeriod = .week
    private var cal: Calendar { DateHelpers.calendar }

    var body: some View {
        VStack(spacing: 16) {
            Picker("기간", selection: $period) {
                ForEach(StatsPeriod.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                summaryCard(title: "남긴 기록", value: "\(filteredRecords.count)", unit: "건",
                            icon: "square.and.pencil", tint: .orange)
                summaryCard(title: "예정된 일정", value: "\(filteredSchedules.count)", unit: "개",
                            icon: "calendar.badge.checkmark", tint: .blue)
            }
            completionCard
            weekdayCard
            timeOfDayCard
            heatmapCard
        }
    }

    // MARK: - Filtering

    private var filteredRecords: [Record] { records.filter(inPeriod) }
    private var filteredSchedules: [Schedule] { schedules.filter(inPeriod) }
    private var filteredTodos: [TodoItem] { todos.filter(inPeriod) }

    private var periodRange: Range<Date> {
        let now = Date()
        let component: Calendar.Component = period == .week ? .weekOfYear : .month
        let interval = cal.dateInterval(of: component, for: now)
        let start = interval?.start ?? DateHelpers.startOfDay(now)
        let end = interval?.end ?? now
        return start..<end
    }

    private func inPeriod<T>(_ item: T) -> Bool {
        let date: Date
        if let s = item as? Schedule { date = s.date }
        else if let r = item as? Record { date = r.date }
        else if let t = item as? TodoItem { date = t.date }
        else { return false }
        return periodRange.contains(date)
    }

    // MARK: - Summary

    private func summaryCard(title: String, value: String, unit: String,
                             icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .tint(tint)
                Spacer()
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: - Completion

    private var completionCard: some View {
        let total = filteredTodos.count
        let done = filteredTodos.filter { $0.completed }.count
        let rate = total > 0 ? Double(done) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("할 일 달성률")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(round(rate * 100)))%")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.green)
                    .contentTransition(.numericText())
            }
            ProgressView(value: rate)
                .tint(.green)
            Text("총 \(total)개의 할 일 중 \(done)개 완료")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: - Weekday Chart

    private var weekdayCard: some View {
        let days = ["월", "화", "수", "목", "금", "토", "일"]
        let stats: [(day: String, count: Int)] = days.map { d in
            let count = filteredSchedules.filter { DateHelpers.koreanDayLabel($0.date) == d }.count
                + filteredRecords.filter { DateHelpers.koreanDayLabel($0.date) == d }.count
                + filteredTodos.filter { DateHelpers.koreanDayLabel($0.date) == d }.count
            return (d, count)
        }
        let maxCount = max(stats.map(\.count).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("요일별 활동량")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chart.bar.fill").foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(stats, id: \.day) { item in
                    BarMark(
                        x: .value("요일", item.day),
                        y: .value("활동", item.count)
                    )
                    .foregroundStyle(item.count == maxCount && item.count > 0 ? Color.accentColor : Color.secondary.opacity(0.4))
                    .cornerRadius(4)
                }
            }
            .frame(height: 120)
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Time of day

    private var timeOfDayCard: some View {
        var morning = 0, afternoon = 0, evening = 0
        for r in filteredRecords {
            let h = r.minutes / 60
            if (6..<12).contains(h) { morning += 1 }
            else if (12..<18).contains(h) { afternoon += 1 }
            else { evening += 1 }
        }
        let dict = ["아침": morning, "오후": afternoon, "저녁/밤": evening]
        let total = max(morning + afternoon + evening, 1)
        let dominant = dict.max(by: { $0.value < $1.value })?.key ?? "아침"
        let (icon, tint, message): (String, Color, String) = {
            switch dominant {
            case "아침": return ("sun.max.fill", .orange, "아침에 기록이 가장 많아요.")
            case "오후": return ("cloud.sun.fill", .blue, "오후에 기록을 많이 남기셨네요.")
            default: return ("moon.fill", .indigo, "저녁과 밤에 집중하시네요.")
            }
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("주로 기록하는 시간")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                bar(label: "아침", count: morning, total: total, tint: .orange)
                bar(label: "오후", count: afternoon, total: total, tint: .blue)
                bar(label: "저녁/밤", count: evening, total: total, tint: .indigo)
            }
        }
        .padding(16)
        .glassCard()
    }

    private func bar(label: String, count: Int, total: Int, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(count) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
        }
    }

    // MARK: - Heatmap

    private var heatmapCard: some View {
        let days = heatmapDays

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("활동 히트맵")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(period.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Image(systemName: "calendar").foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(days, id: \.self) { d in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(heatColor(for: d))
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel("\(DateHelpers.koreanDateLabel(d)) 활동 \(activityCount(on: d))개")
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Text("적음").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                ForEach([0, 1, 3, 5], id: \.self) { n in legend(n: n) }
                Text("많음").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard()
    }

    private var heatmapDays: [Date] {
        var days: [Date] = []
        var cursor = DateHelpers.startOfDay(periodRange.lowerBound)
        while cursor < periodRange.upperBound {
            days.append(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private func heatColor(for date: Date) -> Color {
        heatColor(forCount: activityCount(on: date))
    }

    private func activityCount(on date: Date) -> Int {
        schedules.filter({ cal.isDate($0.date, inSameDayAs: date) }).count
            + records.filter({ cal.isDate($0.date, inSameDayAs: date) }).count
            + todos.filter({ cal.isDate($0.date, inSameDayAs: date) }).count
    }

    private func heatColor(forCount count: Int) -> Color {
        if count == 0 { return Color.secondary.opacity(0.10) }
        if count <= 2 { return Color.accentColor.opacity(0.30) }
        if count <= 4 { return Color.accentColor.opacity(0.55) }
        return Color.accentColor.opacity(0.85)
    }

    private func legend(n: Int) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(heatColor(forCount: n))
            .frame(width: 10, height: 10)
    }
}
