import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.colorScheme) private var scheme
    @Query private var schedules: [Schedule]
    @Query private var records: [Record]
    @Query private var todos: [TodoItem]

    @State private var query = ""
    @State private var selectedSchedule: Schedule?
    @State private var selectedRecord: Record?

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView("검색어를 입력하세요", systemImage: "magnifyingglass")
                } else if matchedSchedules.isEmpty && matchedRecords.isEmpty && matchedTodos.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                } else {
                    List {
                        scheduleSection
                        todoSection
                        recordSection
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background { AppBackground() }
            .navigationTitle("검색")
            .searchable(text: $query, prompt: "기록·할 일·일정 검색")
            .sheet(item: $selectedSchedule) { schedule in
                ScheduleDetailView(schedule: schedule)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thinMaterial)
            }
            .sheet(item: $selectedRecord) { record in
                RecordEditView(record: record)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        trimmedQuery.lowercased()
    }

    private var matchedSchedules: [Schedule] {
        schedules.filter { $0.text.lowercased().contains(normalizedQuery) }
            .sorted { $0.date < $1.date }
    }

    private var matchedRecords: [Record] {
        records.filter { $0.text.lowercased().contains(normalizedQuery) }
            .sorted { $0.date < $1.date }
    }

    private var matchedTodos: [TodoItem] {
        todos.filter { $0.text.lowercased().contains(normalizedQuery) }
            .sorted { $0.date < $1.date }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        if !matchedSchedules.isEmpty {
            Section("일정") {
                ForEach(matchedSchedules) { schedule in
                    Button {
                        selectedSchedule = schedule
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: schedule.iconName)
                                .foregroundStyle(PillColors.colors(for: schedule.colorTheme, dark: scheme == .dark).tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.text).font(.body)
                                Text(DateHelpers.koreanDateLabel(schedule.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var todoSection: some View {
        if !matchedTodos.isEmpty {
            Section("할 일") {
                ForEach(matchedTodos) { todo in
                    HStack(spacing: 10) {
                        Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(todo.text)
                                .strikethrough(todo.completed)
                                .foregroundStyle(todo.completed ? .secondary : .primary)
                            Text(DateHelpers.koreanDateLabel(todo.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordSection: some View {
        if !matchedRecords.isEmpty {
            Section("기록") {
                ForEach(matchedRecords) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.text)
                                .font(.body)
                                .lineLimit(3)
                            HStack {
                                Text(DateHelpers.koreanDateLabel(record.date))
                                Text("·")
                                Text(record.timeText)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
