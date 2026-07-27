import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext
    @Query private var allSchedules: [Schedule]
    @Query private var allRecords: [Record]
    @Query private var allTodos: [TodoItem]

    @StateObject private var syncManager = EventKitSyncManager.shared
    @State private var monthAnchor: Date = DateHelpers.startOfDay(Date())
    @State private var selectedDate: Date = DateHelpers.startOfDay(Date())
    @State private var selectedSchedule: Schedule? = nil
    @State private var didAutoImport = false
    @State private var saveError: String?

    private var cal: Calendar { DateHelpers.calendar }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    syncCard
                    monthCard
                    agendaCard

                    HStack {
                        Text("인사이트")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(TimelinerDesign.muted(for: scheme))
                        Spacer()
                    }
                    .padding(.top, 6)
                    .padding(.leading, 4)

                    StatisticsSection()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 80)
            }
            .background { AppBackground() }
            .navigationTitle("캘린더")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.smooth) {
                            monthAnchor = DateHelpers.startOfDay(Date())
                            selectedDate = monthAnchor
                        }
                    } label: {
                        Text("오늘").fontWeight(.semibold)
                    }
                }
            }
            .sheet(item: $selectedSchedule) { schedule in
                ScheduleDetailView(schedule: schedule)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thinMaterial)
            }
            .alert("저장 실패", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("확인", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .task {
                syncManager.refreshAuthorizationStatus()
                guard !didAutoImport, syncManager.canSyncAnySource else { return }
                didAutoImport = true
                importRollingYear()
            }
        }
    }

    // MARK: - Import

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple 캘린더 · 미리알림 가져오기")
                        .font(.system(size: 15, weight: .bold))
                    Text(syncManager.statusMessage ?? syncManager.permissionSummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 8)

                Button {
                    importRollingYear()
                } label: {
                    if syncManager.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.calendar")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .buttonStyle(.glass)
                .disabled(syncManager.isSyncing)
            }

            HStack(spacing: 8) {
                syncMetric(title: "일정", count: allSchedules.count, color: .green)
                syncMetric(title: "할 일", count: allTodos.count, color: .blue)
                syncMetric(title: "선택일", count: selectedDaySchedules.count + selectedDayTodos.count, color: .orange)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
    }

    private func syncMetric(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(scheme == .dark ? 0.18 : 0.12))
        )
    }

    private func importRollingYear() {
        let today = DateHelpers.startOfDay(Date())
        let start = cal.date(byAdding: .month, value: -6, to: today) ?? today
        let end = cal.date(byAdding: .month, value: 6, to: today) ?? today.addingTimeInterval(31_536_000)
        importItems(from: start, to: end)
    }

    private func importItems(from start: Date, to end: Date) {
        Task {
            guard let result = await syncManager.importItems(
                from: start,
                to: end,
                existingSchedules: allSchedules,
                existingTodos: allTodos
            ) else { return }

            for schedule in result.insertedSchedules {
                modelContext.insert(schedule)
            }

            for todo in result.insertedTodos {
                modelContext.insert(todo)
            }

            for schedule in result.deletedSchedules {
                modelContext.delete(schedule)
            }

            for todo in result.deletedTodos {
                modelContext.delete(todo)
            }

            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                saveError = error.localizedDescription
            }
        }
    }

    // MARK: - Month grid

    private var monthCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text(DateHelpers.koreanMonthLabel(monthAnchor))
                    .font(.system(size: 19, weight: .bold))
                Spacer()
                HStack(spacing: 4) {
                    Button { moveMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.glass)
                    Button { moveMonth(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.glass)
                }
            }

            HStack(spacing: 0) {
                ForEach(["일", "월", "화", "수", "목", "금", "토"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(weekdayColor(d))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 10) {
                ForEach(monthCells, id: \.self) { cell in
                    dayCell(cell)
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 24)
    }

    private func weekdayColor(_ d: String) -> Color {
        switch d {
        case "일": return Color.red.opacity(0.7)
        case "토": return Color.blue.opacity(0.8)
        default: return .secondary
        }
    }

    private struct DayCell: Hashable { let date: Date? }

    private var monthCells: [DayCell] {
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else { return [] }
        let weekday = cal.component(.weekday, from: firstDay) - 1
        var cells: [DayCell] = []
        for _ in 0..<weekday { cells.append(DayCell(date: nil)) }
        for day in range {
            if let d = cal.date(byAdding: .day, value: day - 1, to: firstDay) {
                cells.append(DayCell(date: d))
            }
        }
        return cells
    }

    @ViewBuilder
    private func dayCell(_ cell: DayCell) -> some View {
        if let date = cell.date {
            let isToday = cal.isDateInToday(date)
            let isSelected = cal.isDate(date, inSameDayAs: selectedDate)
            let hasSchedule = allSchedules.contains { cal.isDate($0.date, inSameDayAs: date) }
            let hasRecord = allRecords.contains { cal.isDate($0.date, inSameDayAs: date) }
            let hasTodo = allTodos.contains { cal.isDate($0.date, inSameDayAs: date) }

            Button {
                withAnimation(.smooth(duration: 0.15)) { selectedDate = date }
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                        Text("\(cal.component(.day, from: date))")
                            .font(.system(size: 14, weight: (isSelected || isToday) ? .bold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .frame(width: 34, height: 34)

                    HStack(spacing: 3) {
                        if hasSchedule {
                            Circle().fill(isSelected ? Color.white.opacity(0.7) : Color.green)
                                .frame(width: 4, height: 4)
                        }
                        if hasTodo {
                            Circle().fill(isSelected ? Color.white.opacity(0.7) : Color.blue)
                                .frame(width: 4, height: 4)
                        }
                        if hasRecord {
                            Circle().fill(isSelected ? Color.white.opacity(0.7) : Color.orange)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(height: 50)
        }
    }

    private func moveMonth(_ delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            withAnimation(.smooth) { monthAnchor = next }
        }
    }

    // MARK: - Agenda

    private var agendaCard: some View {
        let dayString = DateHelpers.koreanDateLabel(selectedDate)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(dayString) 일정")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(DateHelpers.koreanDayLabel(selectedDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if selectedDaySchedules.isEmpty && selectedDayTodos.isEmpty {
                ContentUnavailableView {
                    Label("일정 없음", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("이 날엔 등록된 일정이나 할 일이 없습니다.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(selectedDaySchedules) { schedule in
                        ScheduleRowView(schedule: schedule) { selectedSchedule = schedule }
                    }
                    ForEach(selectedDayTodos) { todo in
                        TodoRowView(todo: todo)
                    }
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 24)
    }

    private var selectedDaySchedules: [Schedule] {
        allSchedules.filter { cal.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { sortableMinutes($0.timeString) < sortableMinutes($1.timeString) }
    }

    private var selectedDayTodos: [TodoItem] {
        allTodos.filter { cal.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func sortableMinutes(_ str: String?) -> Int {
        guard let s = str, !s.isEmpty else { return -1 }
        return DateHelpers.minutesSinceMidnight(from: s)
    }
}
