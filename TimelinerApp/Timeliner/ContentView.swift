import SwiftUI
import SwiftData

enum AppTab: String, Hashable, CaseIterable {
    case timeline, todo, calendar, settings

    var title: String {
        switch self {
        case .timeline: return "타임라인"
        case .todo: return "할 일"
        case .calendar: return "캘린더"
        case .settings: return "설정"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: return "list.bullet.indent"
        case .todo: return "checklist"
        case .calendar: return "calendar"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var dataStore: DataStore
    @State private var selection: AppTab = .timeline
    @State private var recordAddedPulse: Int = 0
    @State private var recordInputDraft = RecordInputDraft()
    @State private var composerPresented = false
    @State private var pillFrameBox = PillFrameBox()
    @State private var currentDate = Date()

    var body: some View {
        ZStack {
            AppBackground()
                .allowsHitTesting(false)

            Group {
                if #available(iOS 26.1, *) {
                    tabs(usesExternalRecordInput: true)
                        .tabViewBottomAccessory(isEnabled: selection == .timeline) {
                            RecordInputAccessory(
                                draft: recordInputDraft,
                                onTap: presentComposer,
                                onSelectType: { recordInputDraft.entryType = $0 },
                                onFrameChange: { pillFrameBox.rect = $0 }
                            )
                        }
                        .tabBarMinimizeBehavior(.onScrollDown)
                } else {
                    tabs(usesExternalRecordInput: false)
                }
            }
        }
        // Resolved once here so every screen's background draws the same moment, and so
        // the slider has one place to move it from.
        .environment(\.backgroundDate, backgroundDate)
        .preferredColorScheme(effectiveColorScheme)
        .fullScreenCover(isPresented: $composerPresented) {
            RecordComposerView(
                draft: $recordInputDraft,
                isPresented: $composerPresented,
                pillFrame: pillFrameBox.rect,
                onRecordAdded: { recordAddedPulse += 1 }
            )
            .presentationBackground(.clear)
        }
        .task {
            // Only the sample store is ever seeded. The real one is the point of the
            // setting; putting design fixtures in it would defeat it.
            if dataStore.mode == .sample {
                SeedData.populateIfNeeded(context: modelContext)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                    currentDate = Date()
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    /// The composer animates itself out of the pill, so the cover must not add its
    /// own slide-up on top of that.
    private func presentComposer() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { composerPresented = true }
    }

    /// The moment the background draws, which the time slider can move away from the
    /// real one. Nothing about the timeline's own sense of now reads this.
    private var backgroundDate: Date {
        appearance.backgroundDate(now: currentDate)
    }

    private var effectiveColorScheme: ColorScheme? {
        appearance.colorScheme(backgroundDate: backgroundDate)
    }

    private func tabs(usesExternalRecordInput: Bool) -> some View {
        TabView(selection: $selection) {
            Tab(AppTab.timeline.title, systemImage: AppTab.timeline.systemImage, value: AppTab.timeline) {
                TimelineTabView(
                    recordAddedPulse: recordAddedPulse,
                    usesExternalRecordInput: usesExternalRecordInput,
                    onRecordAdded: { recordAddedPulse += 1 }
                )
            }
            Tab(AppTab.todo.title, systemImage: AppTab.todo.systemImage, value: AppTab.todo) {
                TodoListView()
            }
            Tab(AppTab.calendar.title, systemImage: AppTab.calendar.systemImage, value: AppTab.calendar) {
                CalendarView()
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(.accentColor)
    }
}

// MARK: - Shared toolbar pieces

// The theme-cycling toolbar button lived here. Five background modes do not cycle
// usefully through one button, and the settings tab now owns the choice outright.
