import SwiftUI
import SwiftData

/// Making a todo, or changing one that already exists.
///
/// One sheet for both because the two differ in almost nothing: a new todo is an edit
/// of a row that does not exist yet. Keeping them apart would mean two copies of the
/// day-and-sort-order bookkeeping, which is the only part with any subtlety in it.
struct TodoEditView: View {
    enum Mode {
        case edit(TodoItem)
        case create(day: Date)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var syncManager = EventKitSyncManager.shared

    /// Every todo, only ever read to work out where a new one lands in its day.
    @Query private var allTodos: [TodoItem]

    let mode: Mode

    @State private var text: String
    @State private var day: Date
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var focused: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .edit(let todo):
            _text = State(initialValue: todo.text)
            _day = State(initialValue: todo.date)
        case .create(let day):
            _text = State(initialValue: "")
            _day = State(initialValue: DateHelpers.startOfDay(day))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("할 일", text: $text, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                }

                Section {
                    DatePicker(
                        "날짜",
                        selection: $day,
                        displayedComponents: .date
                    )
                } footer: {
                    // Todos are filed by day, not by the hour: `TodoItem.date` is always a
                    // start of day, and where the block lands inside that day comes from
                    // when it was written down. So there is no time to offer here.
                    Text("할 일은 시각 없이 날짜로만 놓입니다.")
                }

                if isLinkedToReminders {
                    Section {
                        Label {
                            Text("Apple 미리알림에도 함께 반영됩니다.")
                        } icon: {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .navigationTitle(isEditing ? "할 일 수정" : "새 할 일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "저장 중" : "저장", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedText.isEmpty || isSaving)
                }
                if case .edit(let todo) = mode {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) { delete(todo) } label: {
                            Label("삭제", systemImage: "trash")
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .onAppear {
                guard !isEditing else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
            }
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

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isLinkedToReminders: Bool {
        if case .edit(let todo) = mode { return todo.reminderIdentifier != nil }
        return false
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Saving

    private func save() {
        let trimmed = trimmedText
        guard !trimmed.isEmpty, !isSaving else { return }
        let newDay = DateHelpers.startOfDay(day)

        switch mode {
        case .create:
            insertTodo(text: trimmed, day: newDay)

        case .edit(let todo):
            // Reminders is written first and the local row only follows if that worked.
            // The same bargain `TodoRowView` makes for completion: a local edit that the
            // source never heard about is undone by the next import anyway, so the two
            // are better off never diverging in the first place.
            guard let identifier = todo.reminderIdentifier else {
                applyEdit(to: todo, text: trimmed, day: newDay)
                return
            }

            isSaving = true
            Task {
                let pushed = await syncManager.updateReminder(
                    identifier: identifier,
                    title: trimmed,
                    dueDate: newDay
                )
                isSaving = false
                guard pushed else {
                    errorMessage = syncManager.statusMessage
                        ?? "Apple 미리알림을 수정하지 못했습니다."
                    return
                }
                applyEdit(to: todo, text: trimmed, day: newDay)
            }
        }
    }

    private func insertTodo(text: String, day: Date) {
        let todo = TodoItem(date: day, text: text, sortOrder: nextSortOrder(on: day))
        modelContext.insert(todo)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.delete(todo)
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func applyEdit(to todo: TodoItem, text: String, day: Date) {
        let previousText = todo.text
        let previousDate = todo.date
        let previousSortOrder = todo.sortOrder

        todo.text = text
        if !DateHelpers.sameDay(todo.date, day) {
            todo.date = day
            // Its old number belonged to the day it left, where it may well collide with
            // a row already sitting there. Landing at the end of the new day is the one
            // position that cannot displace anything.
            todo.sortOrder = nextSortOrder(on: day)
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            todo.text = previousText
            todo.date = previousDate
            todo.sortOrder = previousSortOrder
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ todo: TodoItem) {
        modelContext.delete(todo)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    /// One past the last row of that day, ignoring the todo being edited so moving a row
    /// within its own day does not push it behind itself.
    private func nextSortOrder(on day: Date) -> Int {
        let editingID: UUID? = {
            if case .edit(let todo) = mode { return todo.id }
            return nil
        }()

        return allTodos
            .filter { DateHelpers.sameDay($0.date, day) && $0.id != editingID }
            .map(\.sortOrder)
            .max()
            .map { $0 + 1 } ?? 0
    }
}
