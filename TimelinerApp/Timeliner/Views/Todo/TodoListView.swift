import SwiftUI
import SwiftData

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\TodoItem.date, order: .reverse),
                  SortDescriptor(\TodoItem.sortOrder, order: .forward)])
    private var todos: [TodoItem]

    @State private var showCompleted: Bool = true
    @State private var searchQuery: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "할 일이 없습니다",
                        systemImage: "checkmark.seal",
                        description: Text("타임라인에서 새로운 할 일을 추가해보세요.")
                    )
                } else {
                    list
                }
            }
            .background { AppBackground() }
            .navigationTitle("할 일")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("완료 항목 표시", isOn: $showCompleted)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $searchQuery, prompt: "할 일 검색")
            .alert("저장 실패", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var filtered: [TodoItem] {
        let q = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return todos.filter { todo in
            (showCompleted || !todo.completed)
            && (q.isEmpty || todo.text.lowercased().contains(q))
        }
    }

    private var grouped: [(Date, [TodoItem])] {
        Dictionary(grouping: filtered) { DateHelpers.startOfDay($0.date) }
            .sorted { $0.key > $1.key }
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.0) { date, items in
                Section {
                    ForEach(items) { todo in
                        TodoRowView(todo: todo)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .glassCard(cornerRadius: 16)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(todo)
                                } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(DateHelpers.koreanDateLabel(date))
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text("(\(DateHelpers.koreanDayLabel(date)))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if DateHelpers.sameDay(date, Date()) {
                            Text("오늘")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    .textCase(nil)
                    .padding(.top, 10)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 100, for: .scrollContent)
    }

    private func delete(_ todo: TodoItem) {
        modelContext.delete(todo)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
