import EventKit
import SwiftData
import SwiftUI

/// Making a schedule, or changing one.
///
/// The fields are the ones Apple 캘린더 puts on its own event sheet, minus the two that
/// need an account behind them (invitees and availability). Repeats are not here either:
/// a recurring event is not one row with a rule on it, it is a question about which
/// occurrence an edit means, and that question reaches all the way into the timeline.
struct ScheduleEditView: View {
    enum Mode {
        case edit(Schedule)
        case create(day: Date)
    }

    /// The offsets Apple 캘린더 offers, in the same order.
    private static let alarmChoices: [(label: String, minutes: Int?)] = [
        ("없음", nil),
        ("이벤트 당시", 0),
        ("5분 전", 5),
        ("15분 전", 15),
        ("30분 전", 30),
        ("1시간 전", 60),
        ("2시간 전", 120),
        ("1일 전", 60 * 24)
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var syncManager = EventKitSyncManager.shared
    @StateObject private var notifications = NotificationScheduler.shared

    let mode: Mode

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var notes: String
    @State private var urlString: String
    @State private var alarmMinutesBefore: Int?
    @State private var colorTheme: ScheduleColorTheme
    @State private var calendarIdentifier: String?

    @State private var calendars: [EKCalendar] = []
    @State private var exportToAppleCalendar: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .edit(let schedule):
            let day = DateHelpers.startOfDay(schedule.date)
            let startMoment = schedule.startAt ?? Self.defaultStart(on: day)
            _title = State(initialValue: schedule.text)
            _isAllDay = State(initialValue: schedule.isAllDay)
            _start = State(initialValue: startMoment)
            _end = State(initialValue: schedule.endAt ?? startMoment.addingTimeInterval(3600))
            _location = State(initialValue: schedule.locationText ?? "")
            _notes = State(initialValue: schedule.notes ?? "")
            _urlString = State(initialValue: schedule.urlString ?? "")
            _alarmMinutesBefore = State(initialValue: schedule.alarmMinutesBefore)
            _colorTheme = State(initialValue: schedule.colorTheme)
            _calendarIdentifier = State(initialValue: schedule.calendarIdentifier)
            _exportToAppleCalendar = State(initialValue: schedule.calendarEventIdentifier != nil)
        case .create(let day):
            let startMoment = Self.defaultStart(on: DateHelpers.startOfDay(day))
            _title = State(initialValue: "")
            _isAllDay = State(initialValue: false)
            _start = State(initialValue: startMoment)
            _end = State(initialValue: startMoment.addingTimeInterval(3600))
            _location = State(initialValue: "")
            _notes = State(initialValue: "")
            _urlString = State(initialValue: "")
            _alarmMinutesBefore = State(initialValue: nil)
            _colorTheme = State(initialValue: .blue)
            _calendarIdentifier = State(initialValue: nil)
            _exportToAppleCalendar = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("제목", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($titleFocused)
                    TextField("장소", text: $location)
                }

                Section {
                    Toggle("종일", isOn: $isAllDay.animation(.snappy(duration: 0.2)))
                    if isAllDay {
                        DatePicker("날짜", selection: $start, displayedComponents: .date)
                    } else {
                        DatePicker("시작", selection: $start)
                        DatePicker("종료", selection: $end, in: start...)
                    }
                }

                Section {
                    Picker("알림", selection: $alarmMinutesBefore) {
                        ForEach(Self.alarmChoices, id: \.label) { choice in
                            Text(choice.label).tag(choice.minutes)
                        }
                    }
                } footer: {
                    if alarmMinutesBefore != nil && !notifications.isAuthorized {
                        Text("설정 탭에서 알림을 허용해야 전달됩니다.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Picker("색", selection: $colorTheme) {
                        ForEach(ScheduleColorTheme.allCases, id: \.self) { theme in
                            Text(colorLabel(theme)).tag(theme)
                        }
                    }
                }

                Section {
                    Toggle("Apple 캘린더에 저장", isOn: $exportToAppleCalendar.animation(.snappy(duration: 0.2)))
                    if exportToAppleCalendar {
                        if calendars.isEmpty {
                            Text("쓸 수 있는 캘린더가 없습니다.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("캘린더", selection: $calendarIdentifier) {
                                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                                    Text(calendar.title).tag(Optional(calendar.calendarIdentifier))
                                }
                            }
                        }
                    }
                } footer: {
                    Text(exportToAppleCalendar
                         ? "이 일정이 Apple 캘린더에도 만들어져 다른 기기와 앱에서 보입니다."
                         : "Timeliner 안에만 남습니다.")
                }

                Section("메모") {
                    TextField("메모", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("URL", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle(isEditing ? "일정 수정" : "새 일정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "저장 중" : "저장", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedTitle.isEmpty || isSaving)
                }
                if case .edit(let schedule) = mode {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) { delete(schedule) } label: {
                            Label("삭제", systemImage: "trash")
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .task {
                calendars = await syncManager.writableCalendars()
                if calendarIdentifier == nil {
                    calendarIdentifier = await syncManager.defaultCalendarIdentifier()
                }
                guard !isEditing else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { titleFocused = true }
            }
            .onChange(of: start) { _, newStart in
                // Dragging the start past the end would otherwise leave an event that
                // finishes before it begins, which EventKit refuses at save time — long
                // after the mistake was made.
                if end < newStart { end = newStart.addingTimeInterval(3600) }
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

    // MARK: - Derived

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultStart(on day: Date) -> Date {
        DateHelpers.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    private func colorLabel(_ theme: ScheduleColorTheme) -> String {
        switch theme {
        case .emerald: return "초록"
        case .orange: return "주황"
        case .blue: return "파랑"
        case .purple: return "보라"
        case .gray: return "회색"
        }
    }

    private var parsedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A bare host is what people type; without a scheme `URL` builds something no
        // browser will open.
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: normalized)
    }

    // MARK: - Saving

    private func save() {
        guard !trimmedTitle.isEmpty, !isSaving else { return }
        isSaving = true

        Task {
            let day = DateHelpers.startOfDay(start)
            var eventIdentifier = currentEventIdentifier

            if exportToAppleCalendar {
                let written = await syncManager.exportEvent(
                    title: trimmedTitle,
                    isAllDay: isAllDay,
                    day: day,
                    start: isAllDay ? nil : start,
                    end: isAllDay ? nil : end,
                    location: location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    url: parsedURL,
                    alarmMinutesBefore: alarmMinutesBefore,
                    calendarIdentifier: calendarIdentifier,
                    existingEventIdentifier: eventIdentifier
                )
                guard let written else {
                    isSaving = false
                    errorMessage = syncManager.statusMessage
                        ?? "Apple 캘린더에 저장하지 못했습니다."
                    return
                }
                eventIdentifier = written
            } else if let eventIdentifier {
                // Turned off after having been on: the copy over there is now orphaned,
                // and leaving it behind is how one edit becomes two diverging events.
                await syncManager.deleteExportedEvent(identifier: eventIdentifier)
            }

            applyLocally(day: day, eventIdentifier: exportToAppleCalendar ? eventIdentifier : nil)
            isSaving = false
        }
    }

    private var currentEventIdentifier: String? {
        if case .edit(let schedule) = mode { return schedule.calendarEventIdentifier }
        return nil
    }

    private func applyLocally(day: Date, eventIdentifier: String?) {
        let calendarName = calendars
            .first { $0.calendarIdentifier == calendarIdentifier }?
            .title

        let schedule: Schedule
        switch mode {
        case .edit(let existing):
            schedule = existing
        case .create:
            schedule = Schedule(date: day, text: trimmedTitle)
            modelContext.insert(schedule)
        }

        schedule.date = day
        schedule.text = trimmedTitle
        schedule.isAllDay = isAllDay
        schedule.startAt = isAllDay ? nil : start
        schedule.endAt = isAllDay ? nil : end
        schedule.locationText = location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        schedule.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        schedule.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        schedule.alarmMinutesBefore = alarmMinutesBefore
        schedule.colorTheme = colorTheme
        schedule.calendarIdentifier = calendarIdentifier
        schedule.calendarEventIdentifier = eventIdentifier
        schedule.calendarName = exportToAppleCalendar ? calendarName : "타임라이너"

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ schedule: Schedule) {
        let eventIdentifier = schedule.calendarEventIdentifier
        modelContext.delete(schedule)

        do {
            try modelContext.save()
            if let eventIdentifier {
                Task { await syncManager.deleteExportedEvent(identifier: eventIdentifier) }
            }
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    /// Empty and absent mean the same thing in every one of these fields, and the model
    /// stores the absence.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
