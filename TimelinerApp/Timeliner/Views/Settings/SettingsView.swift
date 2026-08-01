import EventKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var dataStore: DataStore
    @StateObject private var notifications = NotificationScheduler.shared
    @StateObject private var syncManager = EventKitSyncManager.shared
    @Environment(\.colorScheme) private var scheme

    @Query private var schedules: [Schedule]
    @Query private var records: [Record]
    @Query private var todos: [TodoItem]

    @State private var photoItem: PhotosPickerItem?
    @State private var reminderLists: [EKCalendar] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    backgroundCard
                    if appearance.mode == .custom {
                        customBackgroundCard
                    }
                    if appearance.mode == .sky {
                        previewTimeCard
                    }
                    notificationCard
                    reminderSyncCard
                    dataModeCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 80)
            }
            .animation(.snappy(duration: 0.25), value: appearance.mode)
            .macColumn()
            .background { AppBackground() }
            .navigationTitle("설정")
            .macInlineTitle()
        }
    }

    // MARK: - Notifications

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("알림", systemImage: "bell")

            if notifications.isAuthorized {
                Toggle("하루 요약", isOn: Binding(
                    get: { notifications.digestEnabled },
                    set: { notifications.digestEnabled = $0 }
                ))

                if notifications.digestEnabled {
                    HStack {
                        Text("보낼 시각")
                            .font(.subheadline)
                        Spacer()
                        Text(DateHelpers.format12Hour(fromHHmm: digestHHmm))
                            .font(.subheadline.bold())
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(notifications.digestMinutes) },
                            set: { notifications.digestMinutes = Int($0) }
                        ),
                        in: 0...1_439,
                        step: 5
                    )
                }

                Text("그날 할 일과 일정이 있을 때만 보냅니다. 할 일 하나하나의 알림은 그 할 일을 열어서 켭니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(notifications.authorizationStatus == .denied
                     ? "\(PrivacySettings.appName)에서 Timeliner의 알림을 켜야 합니다."
                     : "할 일과 하루 요약을 알리려면 알림 권한이 필요합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if notifications.authorizationStatus == .denied {
                    Button("\(PrivacySettings.appName) 열기") {
                        PrivacySettings.open(.notifications)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button("알림 허용") {
                        Task { await notifications.requestAuthorization() }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20)
        .animation(.snappy(duration: 0.25), value: notifications.digestEnabled)
        .task { await notifications.refreshAuthorizationStatus() }
    }

    private var digestHHmm: String {
        String(format: "%02d:%02d", notifications.digestMinutes / 60, notifications.digestMinutes % 60)
    }

    // MARK: - Reminders

    /// Where new todos go, answered once for the whole app.
    ///
    /// The edit sheet has its own switch, but two of the three ways to write a todo — the
    /// row at the bottom of each day, the timeline composer — are a line and a return key
    /// with nowhere to put a question. This is where that question gets asked instead.
    private var reminderSyncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Apple 미리알림", systemImage: "checklist")

            Toggle("새 할 일을 미리알림에도 추가", isOn: Binding(
                get: { syncManager.exportsNewTodos },
                set: { syncManager.exportsNewTodos = $0 }
            ))

            if syncManager.exportsNewTodos {
                if reminderLists.isEmpty {
                    Text(syncManager.canSyncReminders
                         ? "쓸 수 있는 미리알림 목록이 없습니다."
                         : "미리알림 접근 권한이 필요합니다. \(PrivacySettings.appName)에서 허용해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("목록", selection: Binding(
                        get: { syncManager.defaultReminderList },
                        set: { syncManager.defaultReminderList = $0 }
                    )) {
                        ForEach(reminderLists, id: \.calendarIdentifier) { list in
                            Text(list.title).tag(list.calendarIdentifier)
                        }
                    }
                }
            }

            Text(syncManager.exportsNewTodos
                 ? "어디에서 적든 미리알림에도 만들어집니다. 하나만 예외로 두려면 그 할 일을 열어서 끄면 됩니다."
                 : "할 일을 열어서 켠 것만 미리알림에 만들어집니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20)
        .animation(.snappy(duration: 0.25), value: syncManager.exportsNewTodos)
        // Reading the lists is what asks for 미리알림 access, so it waits until the switch
        // says someone wants it.
        .task { if syncManager.exportsNewTodos { await loadReminderLists() } }
        .onChange(of: syncManager.exportsNewTodos) { _, isOn in
            guard isOn, reminderLists.isEmpty else { return }
            Task { await loadReminderLists() }
        }
    }

    private func loadReminderLists() async {
        reminderLists = await syncManager.reminderLists()
        // Also covers a list deleted or turned read-only since it was chosen: the picker
        // would show nothing selected while holding an identifier nothing resolves.
        let known = reminderLists.contains { $0.calendarIdentifier == syncManager.defaultReminderList }
        if !known {
            syncManager.defaultReminderList = await syncManager.defaultReminderListIdentifier() ?? ""
        }
    }

    // MARK: - Background mode

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("배경", systemImage: appearance.mode.systemImage)

            Picker("배경", selection: modeBinding) {
                ForEach(BackgroundMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(appearance.mode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20)
    }

    private var modeBinding: Binding<BackgroundMode> {
        Binding(get: { appearance.mode }, set: { appearance.mode = $0 })
    }

    // MARK: - Preview time

    /// Only offered under `하늘`, which is the only mode that has anything to say about
    /// the hour.
    private var previewTimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                cardHeader("하늘 시각", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                Spacer()
                Text(appearance.usesPreviewTime ? previewLabel : "현재 시각")
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundStyle(appearance.usesPreviewTime ? Color.accentColor : .secondary)
            }

            Slider(
                value: previewBinding,
                in: 0...1_439,
                step: 5
            )

            HStack(spacing: 10) {
                Button("현재 시각으로") {
                    appearance.resetPreviewTime()
                }
                .buttonStyle(.glass)
                .disabled(!appearance.usesPreviewTime)

                Spacer(minLength: 0)

                Text("배경만 움직입니다. 타임라인의 '지금'은 실제 시각에 그대로 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20)
    }

    /// Reading the slider when it is off gives it the real clock, so the handle starts
    /// where the eye already is rather than snapping back to midnight.
    private var previewBinding: Binding<Double> {
        Binding(
            get: {
                appearance.usesPreviewTime
                    ? Double(appearance.previewMinutes)
                    : Double(DateHelpers.minutesSinceMidnight(from: Date()))
            },
            set: { appearance.previewMinutes = Int($0) }
        )
    }

    private var previewLabel: String {
        let minutes = appearance.previewMinutes
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Custom background

    private var customBackgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("커스텀 배경", systemImage: "photo.on.rectangle.angled")

            Picker("출처", selection: sourceBinding) {
                ForEach(CustomBackgroundSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            switch appearance.customSource {
            case .photo:
                photoSource
            case .unsplash:
                unsplashSource
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20)
    }

    private var sourceBinding: Binding<CustomBackgroundSource> {
        Binding(get: { appearance.customSource }, set: { appearance.customSource = $0 })
    }

    private var photoSource: some View {
        // Read out here rather than inside the picker's label, which is a sendable
        // closure and cannot reach back into the main-actor settings object.
        let hasPhoto = appearance.hasCustomPhoto
        return HStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
                Label(hasPhoto ? "사진 변경" : "사진 고르기", systemImage: "photo")
            }
            .buttonStyle(.glass)
            .onChange(of: photoItem) { _, item in
                loadPhoto(item)
            }

            Text(hasPhoto ? "고른 사진이 배경으로 쓰이고 있습니다." : "아직 고른 사진이 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unsplashSource: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(UnsplashBackground.all) { background in
                        let isSelected = background.id == appearance.unsplashBackgroundID
                        UnsplashImage(background: background, width: 200, height: 320)
                            .frame(width: 66, height: 106)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        isSelected ? Color.accentColor : Color.white.opacity(0.25),
                                        lineWidth: isSelected ? 3 : 1
                                    )
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                appearance.unsplashBackgroundID = background.id
                            }
                            .accessibilityLabel("\(background.author)의 사진")
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .frame(height: 110)

            // Unsplash asks for the photographer and a link back, and it costs one line.
            let selected = UnsplashBackground.named(appearance.unsplashBackgroundID)
            Link(destination: selected.sourceURL) {
                HStack(spacing: 4) {
                    Text("사진: \(selected.author) · Unsplash")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            appearance.storeCustomPhoto(data)
            photoItem = nil
        }
    }

    // MARK: - Data mode

    private var dataModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("데이터 모드", systemImage: "cylinder.split.1x2")

            Picker("데이터 모드", selection: dataModeBinding) {
                ForEach(DataMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(dataStore.mode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 0) {
                countColumn("일정", schedules.count)
                countColumn("할 일", todos.count)
                countColumn("기록", records.count)
            }

            Label(
                "개발용 설정입니다. 두 저장소는 서로를 보지 못하므로, 전환해도 반대쪽 데이터는 그대로 남습니다.",
                systemImage: "hammer"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20)
    }

    private var dataModeBinding: Binding<DataMode> {
        Binding(get: { dataStore.mode }, set: { dataStore.select($0) })
    }

    private func countColumn(_ title: String, _ count: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func cardHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.bold())
            .foregroundStyle(TimelinerDesign.foreground(for: scheme))
    }
}
