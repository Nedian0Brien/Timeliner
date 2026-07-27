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
    @State private var composingNew = false

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("할 일이 없습니다", systemImage: "checkmark.seal")
                    } description: {
                        Text("여기서 바로 하나 적어보세요.")
                    } actions: {
                        Button("할 일 추가") { composingNew = true }
                            .buttonStyle(.glassProminent)
                    }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composingNew = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("할 일 추가")
                }
            }
            .sheet(isPresented: $composingNew) {
                TodoEditView(mode: .create(day: Date()))
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
                    .onMove { offsets, destination in
                        move(offsets, to: destination, visible: items, on: date)
                    }

                    // Adding to *this* day without going through a sheet and picking the
                    // date back out of it. Hidden while searching, where a row appended
                    // to a filtered list would land somewhere the query does not match
                    // and vanish as it is typed.
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AddTodoRow(date: date, nextSortOrder: nextSortOrder(after: items))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .glassCard(cornerRadius: 16)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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

    /// One past the last row of that day.
    ///
    /// Counted over every todo of the day rather than the ones on screen: with completed
    /// items hidden, numbering from the visible list would hand out an order a hidden row
    /// already holds, and the two would then sort against each other arbitrarily.
    private func nextSortOrder(after items: [TodoItem]) -> Int {
        guard let day = items.first?.date else { return 0 }
        return todos
            .filter { DateHelpers.sameDay($0.date, day) }
            .map(\.sortOrder)
            .max()
            .map { $0 + 1 } ?? 0
    }

    /// Reorders within one day.
    ///
    /// The drag happens on what is on screen, which with completed items hidden is only
    /// part of the day. So the move is applied to the visible rows, and then written back
    /// over the day's full list slot by slot: a slot held by a hidden row keeps it, and
    /// the visible rows are dealt into the slots they already occupied, in their new
    /// order. Renumbering the visible rows 0…n instead would quietly shuffle the hidden
    /// ones — you would turn the filter back on and find a different list than you left.
    private func move(_ offsets: IndexSet, to destination: Int, visible: [TodoItem], on day: Date) {
        var reordered = visible
        reordered.move(fromOffsets: offsets, toOffset: destination)

        let dayTodos = todos
            .filter { DateHelpers.sameDay($0.date, day) }
            .sorted { $0.sortOrder < $1.sortOrder }
        let visibleIDs = Set(visible.map(\.id))
        let previousOrders = dayTodos.map(\.sortOrder)

        var incoming = reordered.makeIterator()
        withAnimation(.snappy(duration: 0.25)) {
            for (slot, occupant) in dayTodos.enumerated() {
                if visibleIDs.contains(occupant.id) {
                    incoming.next()?.sortOrder = slot
                } else {
                    occupant.sortOrder = slot
                }
            }
        }

        do {
            try modelContext.save()
        } catch {
            for (todo, order) in zip(dayTodos, previousOrders) {
                todo.sortOrder = order
            }
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
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
