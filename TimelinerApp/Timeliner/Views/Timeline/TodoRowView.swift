import SwiftUI
import SwiftData

struct TodoRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var todo: TodoItem
    @StateObject private var syncManager = EventKitSyncManager.shared
    @State private var isUpdating = false
    @State private var errorMessage: String?

    var body: some View {
        Button(action: toggleCompletion) {
            HStack(spacing: 12) {
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        .font(.body)
                        .foregroundStyle(todo.completed ? .secondary : .primary)
                        .strikethrough(todo.completed)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if todo.reminderIdentifier != nil {
                        Text("Apple 미리알림")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
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
                .font(.body)
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
        } catch {
            modelContext.delete(todo)
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
