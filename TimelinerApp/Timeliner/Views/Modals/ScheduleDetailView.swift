import SwiftData
import SwiftUI

struct ScheduleDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext

    let schedule: Schedule

    /// Every record filed on this event's day, narrowed to the event's span below.
    ///
    /// The narrowing could be a predicate now that both sides are `Date`s, but the span
    /// is read off the schedule at body time and a `@Query` predicate is fixed at init.
    ///
    /// It is a query rather than a value passed in so that a record added here lands in
    /// the list underneath without anything having to tell it to.
    @Query private var dayRecords: [Record]

    @State private var draft = ""
    @State private var editing = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    init(schedule: Schedule) {
        self.schedule = schedule
        let day = DateHelpers.startOfDay(schedule.date)
        _dayRecords = Query(
            filter: #Predicate<Record> { $0.date == day },
            sort: [SortDescriptor(\Record.createdAt, order: .forward)]
        )
    }

    var body: some View {
        let pill = PillColors.colors(for: schedule.colorTheme, dark: scheme == .dark)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(pill: pill)
                    dayRow
                    if schedule.calendarName != nil || schedule.locationText != nil {
                        detailsRow
                    }
                    miniTimeline(pill: pill)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                composer(pill: pill)
            }
            .navigationTitle("일정 상세")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("수정") { editing = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .sheet(isPresented: $editing) {
                ScheduleEditView(mode: .edit(schedule))
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

    // MARK: - Header

    private func header(pill: PillColorPair) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(pill.tint)
                    .frame(width: 56, height: 56)
                Image(systemName: schedule.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.text)
                    .font(.title2.bold())
                Label(timeRange, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var dayRow: some View {
        HStack {
            Label(DateHelpers.koreanDateLabel(schedule.date), systemImage: "calendar")
            Spacer()
            Text("(\(DateHelpers.koreanDayLabel(schedule.date)))")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private var detailsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let calendarName = schedule.calendarName {
                Label(calendarName, systemImage: "calendar.circle.fill")
            }
            if let location = schedule.locationText, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
            }
            if schedule.isAllDay {
                Label("종일", systemImage: "sun.horizon")
            }
            if let minutes = schedule.alarmMinutesBefore {
                Label(alarmLabel(minutes), systemImage: "bell")
            }
            if let notes = schedule.notes, !notes.isEmpty {
                Label {
                    Text(notes)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.alignleft")
                }
            }
            if let urlString = schedule.urlString, !urlString.isEmpty {
                if let url = URL(string: urlString.contains("://") ? urlString : "https://\(urlString)") {
                    Link(destination: url) {
                        Label(urlString, systemImage: "link")
                    }
                } else {
                    // Still shown rather than hidden: a half-typed address the user can
                    // see is fixable, one the sheet silently drops is not.
                    Label(urlString, systemImage: "link")
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private func alarmLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "이벤트 당시 알림"
        case ..<60: return "\(minutes)분 전 알림"
        case 60 * 24: return "1일 전 알림"
        default: return "\(minutes / 60)시간 전 알림"
        }
    }

    // MARK: - Mini timeline

    /// The event's own stretch of the day, drawn in the event's colour so it reads as
    /// belonging to this card rather than as a second, unrelated timeline.
    private func miniTimeline(pill: PillColorPair) -> some View {
        let records = nestedRecords

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("기록")
                    .font(.subheadline.bold())
                Spacer()
                if !records.isEmpty {
                    Text("\(records.count)개")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if records.isEmpty {
                Text("아직 기록이 없어요")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        miniRow(
                            record,
                            pill: pill,
                            isFirst: index == 0,
                            isLast: index == records.count - 1
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    /// The connector is drawn per row rather than as one line behind the stack, so the
    /// first and last rows can stop it at their own node instead of letting it overhang
    /// the ends of the list.
    private func miniRow(
        _ record: Record,
        pill: PillColorPair,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? .clear : pill.tint.opacity(0.35))
                    .frame(width: 2, height: 6)
                Circle()
                    .fill(pill.tint)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(isLast ? .clear : pill.tint.opacity(0.35))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.timeText)
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .foregroundStyle(pill.tint)
                Text(record.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    // MARK: - Composer

    /// The same glass pill the timeline's input bar is, rather than a flat toolbar —
    /// this is the same act in a smaller place, and it should look like it.
    ///
    /// Padded rather than given a fixed height, so the capsule grows with the field
    /// instead of clipping the second line.
    private func composer(pill: PillColorPair) -> some View {
        HStack(spacing: 8) {
            TextField("이 일정에 기록 추가", text: $draft, axis: .vertical)
                .font(.callout)
                .lineLimit(1...4)
                .tint(pill.tint)
                .focused($inputFocused)

            Button(action: addRecord) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSubmit ? .white : pill.foreground.opacity(0.55))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(pill.tint.opacity(canSubmit ? 1 : 0.24)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("기록 추가")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addRecord() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let moment = momentInsideSpan()
        modelContext.insert(Record(occurredAt: moment, text: trimmed))

        do {
            try modelContext.save()
            draft = ""
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    /// Clamped into the event, which is the whole mechanism: nesting is by time
    /// containment, so a record only belongs to this event by virtue of when it is.
    private func momentInsideSpan() -> Date {
        let day = DateHelpers.startOfDay(schedule.date)
        let start = schedule.startAt ?? day
        let end = max(start, schedule.endAt ?? start)
        let now = Date()
        // A day that is not today has no "now" inside it to borrow; those land on the
        // event's end so they still fall within it.
        let reference = DateHelpers.sameDay(schedule.date, now) ? now : end
        return min(max(reference, start), end)
    }

    private var nestedRecords: [Record] {
        guard let start = schedule.startAt else { return [] }
        let end = schedule.endAt ?? start.addingTimeInterval(3600)

        return dayRecords
            .filter { $0.occurredAt >= start && $0.occurredAt <= end }
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    private var timeRange: String {
        guard let startText = schedule.startText else { return "하루 종일" }
        guard let endText = schedule.endText else { return startText }
        return "\(startText) – \(endText)"
    }
}
