import SwiftUI
import SwiftData

struct TodoRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var todo: TodoItem
    @StateObject private var syncManager = EventKitSyncManager.shared
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var editing = false
    /// Shown only where a drag actually reorders something — the todo list. The timeline
    /// and the calendar draw the same row with no `onMove` behind it.
    var showsReorderHandle = false

    // The row carries two actions, so it is two buttons rather than one. Ticking a todo
    // off and opening it to change the wording are both things you reach for by tapping
    // the row, and the only place to put that boundary is where the eye already reads
    // one: the circle is the state, the words are the todo.
    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleCompletion) {
                ZStack {
                    Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(todo.completed ? Color.accentColor : .secondary)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(isUpdating ? 0 : 1)
                    if isUpdating {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                // Widened past the glyph so the circle is a comfortable target without
                // taking a bite out of the text's.
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .accessibilityLabel(todo.completed ? "완료 해제" : "완료로 표시")

            Button { editing = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        // Matches a record's body. The two sit on the same rail a few
                        // points apart, and a todo set two sizes larger read as a
                        // heading over the records under it rather than a sibling.
                        .font(.subheadline)
                        .foregroundStyle(todo.completed ? .secondary : .primary)
                        .strikethrough(todo.completed)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if todo.reminderIdentifier != nil {
                        Text("Apple 미리알림")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(todo.text) 수정")
            .accessibilityHint("할 일의 내용과 날짜를 바꿉니다.")

            if showsReorderHandle {
                // Drawn, not wired: the drag is `List`'s own, started by a long press
                // anywhere on the row including here. Without the glyph the gesture was
                // there but nothing said so, which is the same as not having it.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $editing) {
            TodoEditView(mode: .edit(todo))
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

    private func toggleCompletion() {
        guard !isUpdating else { return }
        let nextValue = !todo.completed

        if let reminderIdentifier = todo.reminderIdentifier {
            isUpdating = true
            Task {
                let didUpdateReminder = await syncManager.setReminderCompleted(identifier: reminderIdentifier, completed: nextValue)
                guard didUpdateReminder else {
                    isUpdating = false
                    errorMessage = syncManager.statusMessage ?? "Apple 미리알림 상태를 변경하지 못했습니다."
                    return
                }
                saveLocalCompletion(nextValue)
                isUpdating = false
            }
        } else {
            saveLocalCompletion(nextValue)
        }
    }

    private func saveLocalCompletion(_ completed: Bool) {
        let previousValue = todo.completed
        let previousCompletedAt = todo.completedAt
        withAnimation(.snappy(duration: 0.2)) {
            todo.completed = completed
            // Stamped here rather than derived later: once a block is finished the
            // timeline places it at the moment it was finished, and that moment has to
            // survive the app being closed.
            todo.completedAt = completed ? Date() : nil
        }

        do {
            try modelContext.save()
        } catch {
            todo.completed = previousValue
            todo.completedAt = previousCompletedAt
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

struct AddTodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var syncManager = EventKitSyncManager.shared
    let date: Date
    let nextSortOrder: Int
    @State private var text: String = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .opacity(0.7)

            TextField("새로운 할 일", text: $text)
                .font(.subheadline)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
        .padding(.vertical, 2)
        .alert("저장 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let todo = TodoItem(date: date, text: trimmed, completed: false, sortOrder: nextSortOrder)
        modelContext.insert(todo)

        do {
            try modelContext.save()
            text = ""
            // After the local save, and not waited on: the field is already empty and
            // ready for the next line.
            syncManager.exportNewTodo(todo, context: modelContext)
        } catch {
            modelContext.delete(todo)
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
