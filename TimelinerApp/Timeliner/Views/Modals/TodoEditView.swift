import EventKit
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

    /// Whether the last todo saved went to 미리알림, so the next new one starts the same
    /// way. Someone who keeps their todos in Reminders keeps all of them there, and
    /// making that two extra taps per row is how a sync feature stops being used.
    private static let exportDefaultKey = "todoExportsToReminders"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var syncManager = EventKitSyncManager.shared
    @StateObject private var notifications = NotificationScheduler.shared

    /// Every todo, only ever read to work out where a new one lands in its day.
    @Query private var allTodos: [TodoItem]

    let mode: Mode

    @State private var text: String
    @State private var day: Date
    @State private var reminderAt: Date?
    @State private var exportToReminders: Bool
    @State private var reminderListIdentifier: String?
    @State private var reminderLists: [EKCalendar] = []
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var focused: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .edit(let todo):
            _text = State(initialValue: todo.text)
            _day = State(initialValue: todo.date)
            _reminderAt = State(initialValue: todo.reminderAt)
            // A link that already exists is what the toggle reports; the remembered
            // default has no business overriding what this particular todo is.
            _exportToReminders = State(initialValue: todo.reminderIdentifier != nil)
            _reminderListIdentifier = State(initialValue: todo.reminderListIdentifier)
        case .create(let day):
            _text = State(initialValue: "")
            _day = State(initialValue: DateHelpers.startOfDay(day))
            _reminderAt = State(initialValue: nil)
            _exportToReminders = State(initialValue: UserDefaults.standard.bool(forKey: Self.exportDefaultKey))
            _reminderListIdentifier = State(initialValue: nil)
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

                Section {
                    Toggle("알림", isOn: reminderToggle)
                    if reminderAt != nil {
                        DatePicker(
                            "알림 시각",
                            selection: Binding(
                                get: { reminderAt ?? defaultReminderTime },
                                set: { reminderAt = $0 }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } footer: {
                    if let reminderAt, reminderAt <= Date() {
                        // Says it plainly rather than refusing the value. Setting a past
                        // time is a reasonable thing to do on the way to setting a future
                        // one, and a picker that fights you mid-edit is worse than a line
                        // of text.
                        Text("이미 지난 시각이라 알림이 오지 않습니다.")
                            .foregroundStyle(.orange)
                    } else if notifications.isAuthorized == false && reminderAt != nil {
                        Text("설정 탭에서 알림을 허용해야 전달됩니다.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle("Apple 미리알림에 저장", isOn: $exportToReminders.animation(.snappy(duration: 0.2)))
                    if exportToReminders {
                        if reminderLists.isEmpty {
                            Text("쓸 수 있는 미리알림 목록이 없습니다.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("목록", selection: $reminderListIdentifier) {
                                ForEach(reminderLists, id: \.calendarIdentifier) { list in
                                    Label {
                                        Text(list.title)
                                    } icon: {
                                        // Lists in 미리알림 are told apart by colour more
                                        // than by name, and half of them are called some
                                        // variant of "미리알림".
                                        Image(systemName: "circle.fill")
                                            .foregroundStyle(color(of: list))
                                    }
                                    .tag(Optional(list.calendarIdentifier))
                                }
                            }
                        }
                    }
                } footer: {
                    Text(exportToReminders
                         ? "내용·날짜·완료 여부가 Apple 미리알림과 양쪽으로 반영됩니다. 여기서 지우면 미리알림에서도 지워집니다."
                         : "Timeliner 안에만 남습니다.")
                }
            }
            // The sky belongs behind the timeline, where it is telling you the hour. A
            // sheet you came to in order to fix a typo is not the place for weather: the
            // moon drifting behind the text field was legible only by accident. Left on
            // the system's own grouped background, which follows light and dark on its
            // own.
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
            // Loaded only once the switch is actually on. Reading the lists is what asks
            // for 미리알림 access, and a permission sheet has no business appearing over
            // someone who opened this to fix a typo and will never touch the switch.
            .task { if exportToReminders { await loadReminderLists() } }
            .onChange(of: exportToReminders) { _, isOn in
                guard isOn, reminderLists.isEmpty else { return }
                Task { await loadReminderLists() }
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

    private var currentReminderIdentifier: String? {
        if case .edit(let todo) = mode { return todo.reminderIdentifier }
        return nil
    }

    /// A list's own colour, falling back to grey. `EKCalendar.cgColor` is typed as
    /// implicitly unwrapped and is genuinely absent for some accounts.
    private func color(of list: EKCalendar) -> Color {
        guard let cgColor = list.cgColor else { return .secondary }
        return Color(cgColor: cgColor)
    }

    private func loadReminderLists() async {
        reminderLists = await syncManager.reminderLists()
        // Also covers a list that has since been deleted or turned read-only: the picker
        // would otherwise show nothing selected while holding an identifier that no
        // longer resolves.
        let known = reminderLists.contains { $0.calendarIdentifier == reminderListIdentifier }
        if !known {
            reminderListIdentifier = await syncManager.defaultReminderListIdentifier()
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var reminderToggle: Binding<Bool> {
        Binding(
            get: { reminderAt != nil },
            set: { isOn in
                reminderAt = isOn ? defaultReminderTime : nil
                // Asked for the moment it is first switched on, so the prompt lands while
                // the intent is on screen rather than at some later save.
                if isOn { Task { await notifications.requestAuthorization() } }
            }
        )
    }

    /// 9:00 on the day being edited. A todo carries no hour of its own, so the first
    /// alarm has to be invented; morning is the least surprising invention.
    private var defaultReminderTime: Date {
        DateHelpers.calendar.date(
            bySettingHour: 9, minute: 0, second: 0,
            of: DateHelpers.startOfDay(day)
        ) ?? day
    }

    /// The alarm re-pinned to `day`, keeping the hour the picker was left on.
    ///
    /// Without this, moving a todo to next week leaves its alarm on the old date — an
    /// hour the picker still shows, on a day the todo no longer belongs to.
    private func reminder(on newDay: Date) -> Date? {
        guard let reminderAt else { return nil }
        let time = DateHelpers.calendar.dateComponents([.hour, .minute], from: reminderAt)
        return DateHelpers.calendar.date(
            bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0,
            of: DateHelpers.startOfDay(newDay)
        )
    }

    // MARK: - Saving

    /// 미리알림 is written first and the local row only follows if that worked.
    ///
    /// The same bargain `TodoRowView` makes for completion: a local edit the source never
    /// heard about is undone by the next import anyway, so the two are better off never
    /// diverging in the first place.
    private func save() {
        let trimmed = trimmedText
        guard !trimmed.isEmpty, !isSaving else { return }
        let newDay = DateHelpers.startOfDay(day)
        isSaving = true

        Task {
            var identifier = currentReminderIdentifier

            if exportToReminders {
                let written = await syncManager.exportReminder(
                    title: trimmed,
                    day: newDay,
                    listIdentifier: reminderListIdentifier,
                    existingIdentifier: identifier
                )
                guard let written else {
                    isSaving = false
                    errorMessage = syncManager.statusMessage
                        ?? "Apple 미리알림에 저장하지 못했습니다."
                    return
                }
                identifier = written
            } else if let identifier {
                // Switched off after having been on: the copy over there is now orphaned,
                // and leaving it behind is how one todo becomes two that drift apart.
                await syncManager.deleteExportedReminder(identifier: identifier)
            }

            UserDefaults.standard.set(exportToReminders, forKey: Self.exportDefaultKey)
            applyLocally(
                text: trimmed,
                day: newDay,
                reminderIdentifier: exportToReminders ? identifier : nil
            )
            isSaving = false
        }
    }

    private func applyLocally(text: String, day: Date, reminderIdentifier: String?) {
        let todo: TodoItem
        let isNew: Bool
        switch mode {
        case .edit(let existing):
            todo = existing
            isNew = false
        case .create:
            todo = TodoItem(date: day, text: text, sortOrder: nextSortOrder(on: day))
            modelContext.insert(todo)
            isNew = true
        }

        let previousText = todo.text
        let previousDate = todo.date
        let previousSortOrder = todo.sortOrder
        let previousReminder = todo.reminderAt
        let previousIdentifier = todo.reminderIdentifier
        let previousList = todo.reminderListIdentifier

        todo.text = text
        todo.reminderAt = reminder(on: day)
        todo.reminderIdentifier = reminderIdentifier
        // Cleared along with the link: a list remembered for a todo that is no longer
        // over there would be handed straight back to the picker the next time the
        // switch is turned on, pointing at wherever it used to live.
        todo.reminderListIdentifier = reminderIdentifier == nil ? nil : reminderListIdentifier
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
            if isNew {
                modelContext.delete(todo)
            } else {
                todo.text = previousText
                todo.date = previousDate
                todo.sortOrder = previousSortOrder
                todo.reminderAt = previousReminder
                todo.reminderIdentifier = previousIdentifier
                todo.reminderListIdentifier = previousList
            }
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the todo here and, if it has one, its copy in 미리알림.
    ///
    /// The remote removal is fired only after the local save has gone through, and is not
    /// waited on: a reminder that outlives its todo comes back on the next import, which
    /// is recoverable. A todo whose reminder was deleted under a save that then failed is
    /// not.
    private func delete(_ todo: TodoItem) {
        let identifier = todo.reminderIdentifier
        modelContext.delete(todo)

        do {
            try modelContext.save()
            if let identifier {
                Task { await syncManager.deleteExportedReminder(identifier: identifier) }
            }
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
