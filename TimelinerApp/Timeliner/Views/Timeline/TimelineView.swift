import ImageIO
import Observation
import SwiftData
import SwiftUI
import UIKit

private enum ScrollAnchor: Hashable, Sendable {
    case bottom
    /// A day, so the view can be put back on the row it was reading after two more
    /// weeks have been inserted above it.
    case day(Date)
}

private struct TimelineScrollMetrics: Equatable {
    let offsetY: CGFloat
    let viewportHeight: CGFloat
}

@MainActor @Observable
private final class FuturePullVisualState {
    var progress: CGFloat = 0
}

/// Staggered rise for the upcoming list: each card fades, lifts and settles a
/// beat after the one above it.
private struct UpcomingRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isRevealed: Bool
    let step: Int

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed ? 1 : 0)
            .scaleEffect(isRevealed ? 1 : 0.96, anchor: .top)
            .offset(y: isRevealed ? 0 : 34)
            .animation(animation, value: isRevealed)
    }

    private var animation: Animation? {
        guard !reduceMotion else { return nil }
        if isRevealed {
            return .spring(response: 0.5, dampingFraction: 0.76)
                .delay(Double(step) * 0.065)
        }
        // Collapse as one, so re-pulling doesn't replay a reversed cascade.
        return .easeOut(duration: 0.22)
    }
}

private struct FutureRevealGate: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let visualState: FuturePullVisualState
    let isRevealed: Bool

    var body: some View {
        let progress = min(1, max(0, visualState.progress))
        let tensionOffset = isRevealed ? 0 : pow(progress, 0.72) * 28

        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .systemGroupedBackground))

                Circle()
                    .fill(Color.accentColor.opacity(0.86))
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(height: 28 * progress)
                    }

                Circle()
                    .stroke(
                        Color.accentColor.opacity(0.34 + 0.56 * progress),
                        lineWidth: 1.5
                    )

                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)

                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(height: 28 * progress)
                    }
            }
            .frame(width: 28, height: 28)

            Text("다가오는 일정")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.5 + 0.5 * progress))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .opacity(isRevealed ? 0 : progress)
        .scaleEffect(isRevealed ? 0.92 : 0.96 + 0.04 * progress)
        .offset(y: tensionOffset)
        .animation(
            reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
            value: isRevealed
        )
        .allowsHitTesting(false)
        .accessibilityHidden(isRevealed || progress == 0)
        .accessibilityLabel("다가오는 일정 표시 진행률 \(Int(progress * 100)) 퍼센트")
    }
}

private enum CurrentTimePulsePhase: CaseIterable {
    case origin
    case wavefront
    case reset

    var scale: CGFloat {
        switch self {
        case .origin, .reset: return 0.78
        case .wavefront: return 1.7
        }
    }

    var opacity: Double {
        switch self {
        case .origin: return 0.9
        case .wavefront, .reset: return 0
        }
    }

    var animation: Animation {
        switch self {
        case .wavefront: return .easeOut(duration: 1.4)
        case .origin, .reset: return .linear(duration: 0.01)
        }
    }
}

final class RecordImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

/// One photo, filling whatever frame it is given. Sizing and corner treatment belong to
/// the grid around it, which is the only thing that knows how many others there are.
struct RecordPhotoView: View {
    let photoID: UUID
    let photoData: Data
    /// `.fill` crops to the cell for the mosaic; `.fit` shows the whole frame, which is
    /// what the full-screen viewer is for.
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        // The photo hangs off a `Color.clear` rather than sizing the cell itself. A
        // `scaledToFill` image carries an aspect ratio into the stack's negotiation, and
        // in the three-photo grid that let the tall left cell win width off the two on
        // the right, which then sat short of their own column. `Color.clear` accepts
        // whatever it is proposed and has no opinion to bring, so the split is even and
        // the overlay is handed exactly the cell.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                }
            }
            .clipped()
            .task(id: photoID) {
                await load()
            }
    }

    /// Loads unconditionally on every change of `photoID`.
    ///
    /// A `guard image == nil else { return }` used to sit at the top, which was harmless
    /// while a record had one photo and this view was never reused for a different one.
    /// In a grid the cells keep their structural identity as the photos behind them
    /// change, so that guard meant a cell held on to the last photo it decoded: deleting
    /// one photo left the timeline drawing the deleted image in the first cell and every
    /// other photo one place out of position.
    private func load() async {
        // Keyed by the photo, not the record it hangs off. Keyed by the record, every
        // photo on a multi-photo record would collide on one entry and the grid would
        // draw the same image in every cell.
        let key = photoID.uuidString as NSString
        if let cachedImage = RecordImageCache.shared.object(forKey: key) {
            image = cachedImage
            return
        }

        // Whatever is on screen belongs to the photo this cell used to hold, so it goes
        // before the decode rather than after it. A moment of placeholder is the honest
        // state; the wrong photo is not.
        image = nil

        let data = photoData
        guard let decodedCGImage = await Task.detached(priority: .userInitiated, operation: {
            Self.downsampledImage(from: data)
        }).value,
        !Task.isCancelled else { return }

        let decodedImage = UIImage(cgImage: decodedCGImage)
        RecordImageCache.shared.setObject(decodedImage, forKey: key)
        image = decodedImage
    }

    private nonisolated static func downsampledImage(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_200,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}

/// A record's photos as one mosaic.
///
/// The arrangement changes with the count, but the outer shape does not: one rounded
/// slab with square divisions inside, so a record with nine photos reads as a single
/// attachment rather than a gallery pasted into the timeline.
struct RecordPhotoGrid: View {
    let photos: [RecordPhoto]
    /// Passed the index of the cell that was tapped. Each cell owns its own tap so the
    /// card around it can keep meaning "edit this record" — a photo and the text beside
    /// it are two different things to want.
    var onSelect: ((Int) -> Void)?

    /// Hairline, not a margin. Wide gutters would turn the mosaic back into separate
    /// tiles, which is the thing the single outer shape is there to avoid.
    private static let gap: CGFloat = 3

    var body: some View {
        Group {
            switch photos.count {
            case 0:
                EmptyView()

            case 1:
                cell(0)

            case 2:
                HStack(spacing: Self.gap) {
                    cell(0)
                    cell(1)
                }

            // One tall beside two stacked. An even three-across would make each photo a
            // sliver at this width.
            case 3:
                HStack(spacing: Self.gap) {
                    cell(0)
                    VStack(spacing: Self.gap) {
                        cell(1)
                        cell(2)
                    }
                }

            // Everything past four rides on the fourth cell as a count, rather than
            // growing the mosaic until it owns the screen.
            default:
                VStack(spacing: Self.gap) {
                    HStack(spacing: Self.gap) {
                        cell(0)
                        cell(1)
                    }
                    HStack(spacing: Self.gap) {
                        cell(2)
                        cell(3, overflow: photos.count - 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 12))
    }

    /// Tuned per arrangement rather than fixed: two side by side at a single photo's
    /// height would be letterboxed, and a 2×2 at that height would be unreadable.
    private var height: CGFloat {
        switch photos.count {
        case 1: return 155
        case 2: return 120
        case 3: return 165
        default: return 200
        }
    }

    private func cell(_ index: Int, overflow: Int = 0) -> some View {
        let photo = photos[index]
        return RecordPhotoView(photoID: photo.id, photoData: photo.data)
            .overlay {
                if overflow > 0 {
                    ZStack {
                        Color.black.opacity(0.45)
                        Text("+\(overflow)")
                            .font(.title3.bold())
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("사진 \(overflow)장 더")
                }
            }
            // A tap gesture rather than a `Button`: the card behind this is itself
            // tappable, and a button nested inside another one is a fight over the
            // touch. An inner gesture simply wins the hit test.
            .contentShape(.rect)
            .onTapGesture { onSelect?(index) }
    }
}

private extension View {
    /// Real Liquid Glass rather than a flat fill painted to look like it.
    ///
    /// The flat version was opaque enough to cover the sky and the moon behind it; glass
    /// lets them through and picks up its own specular edge, so the hand-drawn border and
    /// shadow that stood in for one are gone.
    func timelineCard(cornerRadius: CGFloat, scheme: ColorScheme) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

private struct DayCountSummary: Identifiable {
    let id: String
    let count: Int
    let tint: Color
}

private struct ScheduleSpan {
    let start: String
    let end: String?
    let duration: String?
}

/// A schedule that is running right now.
private struct ScheduleProgress {
    /// How far through it is, 0 to 1.
    let fraction: Double
    /// "30분 남음"
    let remainingLabel: String
}

/// Where a block of todos sits on the timeline.
///
/// It starts at the moment the earliest item was written down, and once every item in
/// the block is ticked it moves to the moment the last one was — so an open block sits
/// where the work was planned and a finished one sits where it actually ended.
///
/// `completedAt` is missing on anything seeded or synced before it existed, so a fully
/// ticked block with no stamps at all keeps its original position rather than jumping
/// to the epoch.
private func todoBlockMoment(_ items: [TodoItem]) -> Date {
    let day = DateHelpers.startOfDay(items.first?.date ?? Date())
    let created = items.map(\.createdAt).min() ?? day

    guard !items.isEmpty,
          items.allSatisfy(\.completed),
          let finished = items.compactMap(\.completedAt).max(),
          // Ticked on some later day, so there is no hour of *this* day to move to.
          // Yesterday's list finished at 03:46 this morning was stamping 03:46 onto
          // yesterday, which is a time that day never had.
          DateHelpers.sameDay(finished, day)
    else { return created }

    // Only ever forward. A block that has not come round yet sits below the now marker,
    // and letting completion drag it to an earlier hour threw it above the line — off
    // the top of a view that opens parked on that line, which reads as the block simply
    // vanishing.
    return max(finished, created)
}

private enum TimelineRow: Identifiable {
    case schedule(Schedule, nestedRecords: [Record])
    case record(Record)
    case todos([TodoItem])

    var id: String {
        switch self {
        case .schedule(let schedule, _): return "schedule-\(schedule.id)"
        case .record(let record): return "record-\(record.id)"
        case .todos(let todos): return "todos-\(todos.first?.date.timeIntervalSince1970 ?? 0)"
        }
    }

    var sortKey: Int {
        switch self {
        case .schedule(let schedule, _):
            return schedule.startMinutes ?? -1
        case .record(let record):
            return record.minutes
        case .todos(let todos):
            // Was pinned to a made-up 11:45. Now that a block carries a real time it
            // can take its place in the day like everything else.
            return DateHelpers.minutesSinceMidnight(from: todoBlockMoment(todos))
        }
    }

    /// When the row stops occupying the day. Only schedules take up a span; a record or
    /// a todo block is a moment, so it ends where it starts.
    var endKey: Int {
        guard case .schedule(let schedule, _) = self else { return sortKey }
        guard let end = schedule.endMinutes, end > sortKey
        else { return sortKey }
        return end
    }
}

struct TimelineTabView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    let recordAddedPulse: Int
    var usesExternalRecordInput = true
    var onRecordAdded: (() -> Void)?

    @Query(sort: [SortDescriptor(\Schedule.date, order: .forward), SortDescriptor(\Schedule.createdAt, order: .forward)])
    private var schedules: [Schedule]
    @Query(sort: [SortDescriptor(\Record.date, order: .forward), SortDescriptor(\Record.createdAt, order: .forward)])
    private var records: [Record]
    @Query(sort: [SortDescriptor(\TodoItem.date, order: .forward), SortDescriptor(\TodoItem.sortOrder, order: .forward)])
    private var todos: [TodoItem]

    @State private var liveDate = Date()
    @State private var searchQuery = ""
    @State private var selectedSchedule: Schedule?
    @State private var selectedRecord: Record?
    @State private var photoViewer: PhotoViewerTarget?
    @State private var localRecordDraft = RecordInputDraft()
    @State private var localComposerPresented = false
    @State private var localPillFrameBox = PillFrameBox()
    @State private var futureItemsRevealed = false
    @State private var futurePullVisualState = FuturePullVisualState()
    @State private var latestScrollOffsetY: CGFloat = 0
    @State private var currentTimeScrollOffsetY: CGFloat?
    @State private var isPositioningAtCurrentTime = false
    @State private var positioningRequestID = 0
    @State private var positioningSettleID = 0
    @State private var isRestoringFuturePull = false
    @State private var futurePullRestorationID = 0
    @State private var timelineScrollPhase: ScrollPhase = .idle
    @State private var timelineScrollPosition = ScrollPosition(idType: ScrollAnchor.self)

    /// How far back the timeline currently reaches. Grows by a fortnight each time the
    /// top is pulled; the future is not windowed, because what is coming has to be
    /// visible all the way out to be worth anything.
    @State private var loadedPastDays = TimelineTabView.pastWindowDays
    /// 0 at rest, 1 when the overscroll is far enough to commit on release.
    @State private var topPullProgress: CGFloat = 0
    /// Latched while the finger is still down.
    ///
    /// The release cannot be judged by `topPullProgress`: letting go starts the rubber
    /// band snapping back, and the geometry has already reported its way to zero by the
    /// time the phase change arrives. So the threshold is recorded when it is crossed,
    /// and pushing back up before release clears it again.
    @State private var topPullArmed = false
    /// 1 when the top of the loaded range is on screen, and what fades the header in.
    @State private var topEdgeProgress: CGFloat = 0
    @State private var isLoadingOlder = false

    static let pastWindowDays = 14
    /// How far the top has to be pulled past its stop before the pull counts.
    private static let topPullDistance: CGFloat = 88
    /// The header is fully in by the top and fully out this far down.
    private static let headerFadeDistance: CGFloat = 44
    /// Title plus its padding — the room the gate below has to leave for it.
    private static let headerHeight: CGFloat = 54

    /// The time axis. Every row hangs its time here, in one column left of the rail —
    /// inside the cards the times sat at three different x positions (schedule flush
    /// right, record inside the left edge, todo nowhere at all) and there was no single
    /// line to read the day down.
    /// Every horizontal measurement on the rail comes from here. See the type for why
    /// rows must not put `HStack` spacing in front of the rail column.
    private let rail = TimelineRailMetrics.standard

    private var railWidth: CGFloat { rail.railWidth }
    private var cardGap: CGFloat { rail.cardGap }
    /// The time line's height, and therefore the height a marker is centred in — that
    /// is what puts the node level with the numerals rather than with the card.
    private let timeLineHeight: CGFloat = 20
    /// Fills the rail column bar a point either side. Widening the bar costs nothing
    /// horizontally as long as it stays inside the column the rail already reserves.
    private let schedulePillWidth: CGFloat = 22
    private let futureRevealViewportFraction: CGFloat = 0.25
    private let futureHideProgress: CGFloat = 0.05

    var body: some View {
        NavigationStack {
            content
                .background { AppBackground() }
                // The timeline names its own days, so the title bar was repeating what
                // the content already says while taking a large title's worth of height
                // off the top.
                .toolbar(.hidden, for: .navigationBar)
                .sheet(item: $selectedSchedule) { schedule in
                    ScheduleDetailView(schedule: schedule)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.thinMaterial)
                }
                .sheet(item: $selectedRecord) { record in
                    RecordEditView(record: record)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                .fullScreenCover(item: $photoViewer) { target in
                    PhotoViewerView(target: target)
                }
        }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                    liveDate = Date()
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    /// Search kept its results view but lost its field along with the navigation bar —
    /// `.searchable` can only render into that bar. Nothing sets `searchQuery` today, so
    /// this always resolves to the timeline; it is the seam a new entry point plugs into.
    @ViewBuilder
    private var content: some View {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            timeline
        } else {
            searchResults(query: trimmedQuery)
        }
    }

    private var timeline: some View {
        let groups = groupedDays
        let startOfToday = DateHelpers.startOfDay(liveDate)
        let windowStart = pastWindowStart
        let past = groups.filter { $0.date < startOfToday && $0.date >= windowStart }
        let today = groups.first { DateHelpers.sameDay($0.date, liveDate) }
        let future = futureGroups(from: groups)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                topGate

                ForEach(past) { group in
                    timelineGroup(group, portion: .whole)
                        // Named so the view can be put back here once older days have
                        // been inserted above it.
                        .id(ScrollAnchor.day(group.date))
                }

                // Today is cut at the current minute rather than handed over whole. The
                // split used to be by date alone, which put this evening's events above
                // a marker labelled "지금" — the one line in the view that claims to be a
                // boundary was the only one that wasn't.
                if let today {
                    timelineGroup(today, portion: .elapsed)
                }

                // Deliberately carries no pull tension. Offsetting it meant its position
                // came through scroll geometry → state → render, while the scroll itself
                // is applied by the render server — so it could only ever arrive a frame
                // or more late, visibly lagging the rail it is supposed to be fixed to.
                // The gate below still stretches; it is the pull affordance, and being
                // elastic is its job.
                currentTimeMarker
                    .id(ScrollAnchor.bottom)

                // What is left of today, immediately below the marker. The timeline
                // opens parked on that marker, so this is what fills the lower half of
                // the screen on launch.
                if let today {
                    timelineGroup(today, portion: .remaining)
                }

                railTerminus

                if !future.isEmpty {
                    FutureRevealGate(
                        visualState: futurePullVisualState,
                        isRevealed: futureItemsRevealed
                    )

                    upcomingList(future)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .background(.clear)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // Nothing on the timeline is typed into — the pill is a button, and the composer
        // that does take text is a separate full-screen presentation. So the keyboard has
        // no business resizing this scroll view, and letting it try is what left the
        // timeline pushed up: raising the composer's keyboard took 208pt off the viewport
        // and added it to the bottom inset, and on dismissal the two came back on
        // different frames. Landing on the frame where the viewport had returned but the
        // inset had not left the content shifted up by a keyboard's height, with that much
        // blank space under `지금`. Declining the inset outright means there is no
        // restoration to get wrong.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // With no navigation bar there is nothing to keep cards from running into the
        // status bar. `.soft` fades the blur out gradually instead of ending on the
        // hard line a bar would have drawn.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollPosition($timelineScrollPosition, anchor: .bottom)
        .onScrollPhaseChange { oldPhase, newPhase in
            timelineScrollPhase = newPhase

            // Fires on release rather than mid-drag, so the pull can be backed out of by
            // easing off — the same bargain every pull-to-refresh makes.
            if oldPhase == .interacting, newPhase != .interacting, topPullArmed {
                topPullArmed = false
                loadOlder()
            }

            if newPhase == .interacting {
                cancelFuturePullRestoration()
            } else if newPhase == .idle {
                let restorationID = futurePullRestorationID

                // SwiftUI can deliver the final geometry value after the idle
                // phase callback. Defer one run-loop turn so restoration uses
                // the released position rather than the previous frame.
                DispatchQueue.main.async {
                    guard timelineScrollPhase == .idle,
                          futurePullRestorationID == restorationID else { return }
                    restoreIncompleteFuturePull()
                }
            }
        }
        .onScrollGeometryChange(for: TimelineScrollMetrics.self) { geometry in
            TimelineScrollMetrics(
                offsetY: geometry.contentOffset.y + geometry.contentInsets.top,
                viewportHeight: geometry.containerSize.height
            )
        } action: { _, metrics in
            updateFutureReveal(using: metrics)
            updateTopEdge(using: metrics)
        }
        .overlay(alignment: .top) { timelineHeader }
        .safeAreaInset(edge: .bottom) {
            if !usesExternalRecordInput {
                RecordInputBar(
                    draft: localRecordDraft,
                    onTap: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { localComposerPresented = true }
                    },
                    onSelectType: { localRecordDraft.entryType = $0 },
                    onFrameChange: { localPillFrameBox.rect = $0 }
                )
            }
        }
        .onAppear {
            scrollToCurrentTime(
                delay: 0.1,
                animation: reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.25)
            )
        }
        .onChange(of: recordAddedPulse) { _, _ in
            scrollToCurrentTime(
                delay: 0.05,
                animation: reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.3)
            )
        }
        .fullScreenCover(isPresented: $localComposerPresented) {
            RecordComposerView(
                draft: $localRecordDraft,
                isPresented: $localComposerPresented,
                pillFrame: localPillFrameBox.rect,
                onRecordAdded: onRecordAdded
            )
            .presentationBackground(.clear)
        }
    }

    // MARK: - The top of the loaded range

    private var pastWindowStart: Date {
        let today = DateHelpers.startOfDay(liveDate)
        return DateHelpers.calendar.date(byAdding: .day, value: -loadedPastDays, to: today) ?? today
    }

    /// The earliest day anything is filed under.
    ///
    /// Read off the front of the queries, which are already sorted ascending, rather than
    /// by grouping the store — this is consulted on scroll, and grouping every day of
    /// every entry to answer it would be paid for on every frame.
    private var oldestEntryDate: Date? {
        [schedules.first?.date, records.first?.date, todos.first?.date]
            .compactMap { $0 }
            .map(DateHelpers.startOfDay)
            .min()
    }

    private var hasOlderPast: Bool {
        guard let oldest = oldestEntryDate else { return false }
        return oldest < pastWindowStart
    }

    /// Where the loaded range begins, and — while there is more behind it — the handle
    /// for going further back.
    private var topGate: some View {
        HStack(spacing: 8) {
            if isLoadingOlder {
                ProgressView()
                    .controlSize(.small)
                Text("불러오는 중")
            } else if hasOlderPast {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    // Turns over as the pull commits, so the arrow stops pointing at
                    // something that is about to arrive.
                    .rotationEffect(.degrees(180 * Double(topPullProgress)))
                Text(topPullProgress >= 1 ? "놓으면 더 보기" : "당겨서 더 보기")
            } else {
                Image(systemName: "flag")
                    .font(.system(size: 11, weight: .semibold))
                Text("여기가 타임라인의 시작입니다")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(
            topPullProgress > 0 && hasOlderPast
                ? Color.accentColor
                : TimelinerDesign.subtle(for: scheme)
        )
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        // Clears the header, which is an overlay and so sits on exactly this spot — the
        // two only ever come into view together.
        .padding(.top, Self.headerHeight)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: topPullProgress >= 1)
        .accessibilityHidden(!hasOlderPast)
    }

    /// Only over the top of the range, per the ask — the timeline names its own days
    /// everywhere else, and a permanent bar there was taken out for repeating them.
    private var timelineHeader: some View {
        Text("Timeliner")
            // Rounded, and set as a masthead rather than a centred bar title — this is
            // the app naming itself at the top of its own record, not chrome labelling
            // the screen below it.
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(TimelinerDesign.foreground(for: scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lines the title up with the cards, which sit inside the same inset.
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    // Faded out at its lower edge rather than ending on a rule: a hard
                    // line would read as a bar, which is the thing this is not.
                    .mask {
                        LinearGradient(
                            colors: [.black, .black, .black.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea(edges: .top)
            }
            .opacity(Double(topEdgeProgress))
            .allowsHitTesting(false)
            .accessibilityHidden(topEdgeProgress < 0.5)
    }

    private func updateTopEdge(using metrics: TimelineScrollMetrics) {
        let overscroll = max(0, -metrics.offsetY)
        let pull = hasOlderPast && !isLoadingOlder
            ? min(1, overscroll / Self.topPullDistance)
            : 0
        if pull != topPullProgress { topPullProgress = pull }
        if timelineScrollPhase == .interacting {
            topPullArmed = pull >= 1
        }

        let edge = 1 - min(1, max(0, metrics.offsetY) / Self.headerFadeDistance)
        if abs(edge - topEdgeProgress) > 0.01 { topEdgeProgress = edge }
    }

    /// Widens the window, then puts the view back on the day it was showing.
    ///
    /// Without the second half the inserted fortnight would push everything down and the
    /// pull would read as being thrown two weeks backwards, which is not what pulling a
    /// list asks for.
    private func loadOlder() {
        guard !isLoadingOlder, hasOlderPast else { return }

        let today = DateHelpers.startOfDay(liveDate)
        let start = pastWindowStart
        let anchor = groupedDays.first { $0.date >= start && $0.date < today }?.date

        isLoadingOlder = true
        topPullProgress = 0
        loadedPastDays += Self.pastWindowDays

        // A turn later, so the inserted days have been laid out and there is something
        // to scroll to.
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let anchor {
                    timelineScrollPosition.scrollTo(id: ScrollAnchor.day(anchor), anchor: .top)
                }
            }
            isLoadingOlder = false
        }
    }

    /// The timeline ends at the current-time marker. Everything ahead of now is a
    /// plain list — no rail, no axis — so it doesn't read as more timeline.
    private func upcomingList(_ future: [GroupedDay]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("다가오는 일정")
                .font(.footnote.weight(.bold))
                .foregroundStyle(TimelinerDesign.muted(for: scheme))
                .padding(.leading, 4)
                .modifier(UpcomingRevealModifier(isRevealed: futureItemsRevealed, step: 0))

            ForEach(Array(future.enumerated()), id: \.element.id) { index, group in
                upcomingDayCard(group)
                    .modifier(UpcomingRevealModifier(isRevealed: futureItemsRevealed, step: index + 1))
            }
        }
        .allowsHitTesting(futureItemsRevealed)
        .accessibilityHidden(!futureItemsRevealed)
    }

    private func upcomingDayCard(_ group: GroupedDay) -> some View {
        let daySchedules = group.schedules.sorted { ($0.startMinutes ?? -1) < ($1.startMinutes ?? -1) }
        let dayTodos = group.todos.sorted { $0.sortOrder < $1.sortOrder }
        let dayRecords = group.records.sorted { $0.occurredAt < $1.occurredAt }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(DateHelpers.slashDateLabel(group.date))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(TimelinerDesign.foreground(for: scheme))
                Text(DateHelpers.koreanDayLabel(group.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TimelinerDesign.muted(for: scheme))
                Spacer(minLength: 6)
                if let away = daysAwayLabel(for: group.date) {
                    Text(away)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TimelinerDesign.subtle(for: scheme))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(daySchedules) { upcomingScheduleRow($0) }
                ForEach(dayTodos) { upcomingTodoRow($0) }
                ForEach(dayRecords) { upcomingRecordRow($0) }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCard(cornerRadius: 18, scheme: scheme)
    }

    private func upcomingScheduleRow(_ schedule: Schedule) -> some View {
        let pill = PillColors.colors(for: schedule.colorTheme, dark: scheme == .dark)
        return Button {
            selectedSchedule = schedule
        } label: {
            upcomingRow(tint: pill.tint) {
                Text(schedule.startText ?? "종일")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(pill.tint)
                    .frame(width: 42, alignment: .leading)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(schedule.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let location = schedule.locationText, !location.isEmpty {
                        Text(location)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func upcomingTodoRow(_ todo: TodoItem) -> some View {
        upcomingRow(tint: TimelinerDesign.success) {
            Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(todo.completed ? TimelinerDesign.success : TimelinerDesign.subtle(for: scheme))
                .frame(width: 42, alignment: .leading)
        } content: {
            Text(todo.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .strikethrough(todo.completed, color: TimelinerDesign.subtle(for: scheme))
                .multilineTextAlignment(.leading)
        }
    }

    private func upcomingRecordRow(_ record: Record) -> some View {
        Button {
            selectedRecord = record
        } label: {
            upcomingRow(tint: TimelinerDesign.subtle(for: scheme)) {
                Text(record.timeText)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(TimelinerDesign.subtle(for: scheme))
                    .frame(width: 42, alignment: .leading)
            } content: {
                Text(record.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func upcomingRow<Leading: View, Content: View>(
        tint: Color,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(tint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            leading()
            content()
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func daysAwayLabel(for date: Date) -> String? {
        let today = DateHelpers.startOfDay(liveDate)
        let target = DateHelpers.startOfDay(date)
        guard let days = DateHelpers.calendar.dateComponents([.day], from: today, to: target).day else {
            return nil
        }
        return days == 1 ? "내일" : "\(days)일 후"
    }

    private func scrollToCurrentTime(
        delay: Double,
        animation: Animation
    ) {
        futurePullRestorationID += 1
        isRestoringFuturePull = false
        isPositioningAtCurrentTime = true
        currentTimeScrollOffsetY = nil
        futurePullVisualState.progress = 0
        futureItemsRevealed = false
        positioningRequestID += 1
        positioningSettleID += 1
        let requestID = positioningRequestID

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard positioningRequestID == requestID else { return }
            withAnimation(animation) {
                timelineScrollPosition.scrollTo(id: ScrollAnchor.bottom, anchor: .bottom)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.42) {
            guard positioningRequestID == requestID else { return }
            currentTimeScrollOffsetY = latestScrollOffsetY
            finishPositioningWhenScrollSettles(requestID: requestID)
        }
    }

    private func updateFutureReveal(using metrics: TimelineScrollMetrics) {
        // A spring restoration must return to the existing threshold. Recalibrating
        // the baseline during that animation makes each incomplete pull move the
        // threshold by the spring's final fractional offset.
        if isRestoringFuturePull {
            return
        }

        if isPositioningAtCurrentTime {
            latestScrollOffsetY = metrics.offsetY
            if currentTimeScrollOffsetY != nil {
                currentTimeScrollOffsetY = metrics.offsetY
                finishPositioningWhenScrollSettles(requestID: positioningRequestID)
            }
            return
        }

        guard let currentTimeScrollOffsetY else { return }

        let pullDistance = max(0, metrics.offsetY - currentTimeScrollOffsetY)
        let revealDistance = max(1, metrics.viewportHeight * futureRevealViewportFraction)
        let progress = min(1, max(0, pullDistance / revealDistance))
        futurePullVisualState.progress = progress

        if !futureItemsRevealed, progress >= 1 {
            withAnimation(reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.82)) {
                futureItemsRevealed = true
            }
        } else if futureItemsRevealed, progress <= futureHideProgress {
            // Scrolled back until "지금" sits at its resting position again, so the
            // list retreats. The reveal threshold is a full pull away, which keeps
            // the two edges far apart enough not to flicker against each other.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                futureItemsRevealed = false
            }
        }
    }

    private func finishPositioningWhenScrollSettles(requestID: Int) {
        positioningSettleID += 1
        let settleID = positioningSettleID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard isPositioningAtCurrentTime,
                  positioningRequestID == requestID,
                  positioningSettleID == settleID else { return }
            currentTimeScrollOffsetY = latestScrollOffsetY
            isPositioningAtCurrentTime = false
        }
    }

    private func cancelFuturePullRestoration() {
        timelineScrollPosition.isPositionedByUser = true
        guard isRestoringFuturePull else { return }

        futurePullRestorationID += 1
        isRestoringFuturePull = false
    }

    private func restoreIncompleteFuturePull() {
        guard !futureItemsRevealed,
              futurePullVisualState.progress > 0,
              futurePullVisualState.progress < 1,
              !isPositioningAtCurrentTime,
              !isRestoringFuturePull,
              let baselineOffsetY = currentTimeScrollOffsetY,
              timelineScrollPhase == .idle else { return }

        isRestoringFuturePull = true
        futurePullRestorationID += 1
        let restorationID = futurePullRestorationID

        withAnimation(
            reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.72),
            completionCriteria: .logicallyComplete
        ) {
            futurePullVisualState.progress = 0
            timelineScrollPosition.scrollTo(y: baselineOffsetY)
        } completion: {
            guard futurePullRestorationID == restorationID else { return }
            futurePullVisualState.progress = 0
            isRestoringFuturePull = false
        }
    }

    /// Which side of the now marker a day's rows are being drawn for.
    private enum DayPortion {
        /// A day that is wholly behind or ahead of now; header and every row.
        case whole
        /// Today up to this minute. Carries the header, so the date still sits above
        /// the marker even on a day whose events are all still to come.
        case elapsed
        /// The rest of today, drawn below the marker without repeating the header.
        case remaining
    }

    @ViewBuilder
    private func timelineGroup(_ group: GroupedDay, portion: DayPortion) -> some View {
        let isToday = DateHelpers.sameDay(group.date, liveDate)
        let dayRows = rows(for: group, portion: portion)

        if portion == .remaining && dayRows.isEmpty {
            // Nothing left today; the rail would otherwise trail off below the marker.
            EmptyView()
        } else {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(TimelinerDesign.line(for: scheme))
                    .frame(width: rail.lineWidth)
                    .offset(x: rail.lineLeadingX)

                VStack(alignment: .leading, spacing: 0) {
                    if portion != .remaining {
                        dateHeader(for: group, isToday: isToday)
                    }

                    ForEach(Array(dayRows.enumerated()), id: \.element.id) { index, row in
                        // Only ahead of now. Free time you can still use is worth
                        // pointing out; a hole in a day already spent is just a gap in
                        // the record, and labelling every one of those turned scrolling
                        // back through the week into an inventory of nothing happening.
                        //
                        // `.remaining` holds exactly the rows after the marker, so the
                        // portion is the whole test — no row pair here straddles now.
                        if portion == .remaining {
                            // Measured from now for the first one, so the stretch
                            // directly under the marker says how long until the next
                            // thing rather than being skipped for want of a predecessor.
                            let previousEnd = index > 0
                                ? dayRows[index - 1].endKey
                                : DateHelpers.minutesSinceMidnight(from: liveDate)
                            let empty = row.sortKey - previousEnd
                            if empty >= Self.emptyStretchThreshold {
                                emptyStretch(minutes: empty)
                            }
                        }
                        timelineRow(row)
                    }
                }
            }
        }
    }

    private func dateHeader(for group: GroupedDay, isToday: Bool) -> some View {
        // .top with a fixed node height, so the node keeps sitting beside the date
        // numerals rather than drifting to the centre of the two-line stack.
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                Circle()
                    .fill(isToday ? Color.accentColor : TimelinerDesign.subtle(for: scheme))
                    .frame(width: 16, height: 16)
                Circle()
                    .stroke(Color.white.opacity(scheme == .dark ? 0.18 : 0.82), lineWidth: 3)
                    .frame(width: 16, height: 16)
            }
            .frame(width: railWidth, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(DateHelpers.slashDateLabel(group.date))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(TimelinerDesign.foreground(for: scheme))
                    Text(DateHelpers.koreanDayLabel(group.date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TimelinerDesign.muted(for: scheme))
                    if let badge = relativeDayBadge(for: group.date) {
                        Text(badge)
                            .font(.caption2.bold())
                            .foregroundStyle(isToday ? .white : TimelinerDesign.muted(for: scheme))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(isToday ? Color.accentColor : TimelinerDesign.line(for: scheme), in: Capsule())
                    }
                }

                dayCountSummary(for: group)
            }
            // Lines the date up with each row's time line, which is the leading edge of
            // everything below it.
            .padding(.leading, cardGap)
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    /// Dot colours match each kind's rail marker, so the tally reads as a legend
    /// for the rows below it. Empty kinds are dropped rather than shown as 0개.
    @ViewBuilder
    private func dayCountSummary(for group: GroupedDay) -> some View {
        let counts = [
            DayCountSummary(id: "일정", count: group.schedules.count, tint: Color.accentColor),
            DayCountSummary(id: "할 일", count: group.todos.count, tint: TimelinerDesign.success),
            DayCountSummary(id: "기록", count: group.records.count, tint: TimelinerDesign.subtle(for: scheme))
        ].filter { $0.count > 0 }

        if !counts.isEmpty {
            HStack(spacing: 10) {
                ForEach(counts) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(entry.tint)
                            .frame(width: 5, height: 5)
                        Text("\(entry.id) \(entry.count)개")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(TimelinerDesign.muted(for: scheme))
                    }
                }
            }
        }
    }

    /// The stretch of day between two items, when it is long enough to be worth saying.
    ///
    /// Rows are spaced evenly, so ten minutes and six hours looked identical. Stating the
    /// number is what fixes that; the extra height is only there to make it *felt*, and
    /// it grows logarithmically because a six-hour hole rendered to scale would cost a
    /// screen and a half of nothing.
    private func emptyStretch(minutes: Int) -> some View {
        // No node on the rail. Every other marker stands for something that happened at
        // that moment, and putting one here would announce an absence as if it were an
        // entry. The line simply runs through, which is what empty should look like.
        HStack(spacing: 5) {
            Image(systemName: "timer")
                .font(.caption2)
            Text(DateHelpers.koreanDuration(minutes: minutes))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(TimelinerDesign.muted(for: scheme).opacity(0.7))
        .padding(.leading, rail.contentLeadingX)
        .frame(height: emptyStretchHeight(forMinutes: minutes), alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("빈 시간 \(DateHelpers.koreanDuration(minutes: minutes))")
    }

    private func emptyStretchHeight(forMinutes minutes: Int) -> CGFloat {
        // Doubles the gap for every 12pt of height: 1h30 ≈ 23, 4h ≈ 40, 8h and up 52.
        let doublings = log2(Double(max(minutes, 60)) / 60)
        return min(16 + CGFloat(doublings) * 12, 52)
    }

    /// Below this a gap is just the rhythm of a busy morning, not a hole in the day.
    private static let emptyStretchThreshold = 90

    /// The line a row leads with: its time, level with the rail marker, sitting directly
    /// above the card it belongs to.
    ///
    /// A column of its own cost 46pt of card width and still left the time and its item
    /// as two separate things to look at. Stacked, they read as one — and because every
    /// row's content starts at the same x, the times still line up into the column you
    /// scan the day down.
    private func timeLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .lineLimit(1)
            .frame(height: timeLineHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Out of the cards and onto a line of its own, the time no longer has to defer to
    /// the text beside it — which is what made it unreadable at `.tertiary` before.
    private func timeText(_ text: String, tint: Color? = nil, strong: Bool = true) -> some View {
        Text(text)
            .font(strong ? .caption.bold() : .caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(
                tint ?? (strong
                    ? TimelinerDesign.foreground(for: scheme)
                    : TimelinerDesign.muted(for: scheme))
            )
    }

    @ViewBuilder
    private func timelineRow(_ row: TimelineRow) -> some View {
        switch row {
        case .schedule(let schedule, let nestedRecords):
            scheduleRow(schedule, nestedRecords: nestedRecords)
        case .record(let record):
            recordRow(record)
        case .todos(let todos):
            todoBlock(todos)
        }
    }

    private func scheduleRow(_ schedule: Schedule, nestedRecords: [Record]) -> some View {
        let pill = PillColors.colors(for: schedule.colorTheme, dark: scheme == .dark)
        let span = scheduleSpan(schedule)
        let progress = scheduleProgress(for: schedule)
        // The bar and the card are siblings in one row, below the time line, rather than
        // two parallel columns each reserving a blank the height of that line. Matching
        // heights by construction beats matching them by arithmetic: as siblings the bar
        // simply fills the row the card sizes, so it cannot come up short.
        return VStack(alignment: .leading, spacing: 6) {
            // Both ends on one line, side by side. Split across the top and bottom of the
            // bar they were never in view together; here you read the span in one go, and
            // the bar beside them still shows how long it runs.
            timeLine {
                HStack(spacing: 5) {
                    timeText(span.start, tint: pill.foreground)
                    if let end = span.end {
                        Text("→")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(TimelinerDesign.muted(for: scheme))
                        timeText(end, strong: false)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, rail.contentLeadingX)

            HStack(alignment: .top, spacing: 0) {
                // Holds the rail column open. The bar itself is an overlay on the card
                // below, not a sibling here — as siblings the two negotiated a height
                // between them and the bar came out taller than the card it was meant to
                // match. Bounded by the card, it cannot.
                Color.clear
                    .frame(width: railWidth)

                Button {
                    selectedSchedule = schedule
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        // Baseline-aligned rather than top-aligned, so the duration sits
                        // on the title's line instead of floating near it.
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(schedule.text)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)

                                HStack(spacing: 7) {
                                    // `foreground`, not `tint`: the card is now tinted
                                    // glass in the same hue, and saturated-on-saturated
                                    // had the label disappearing into its own background.
                                    Label(schedule.calendarName ?? "일정", systemImage: "circle.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(pill.foreground)
                                        .symbolRenderingMode(.monochrome)

                                    if let location = schedule.locationText, !location.isEmpty {
                                        Text("·")
                                        Text(location)
                                            .lineLimit(1)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            durationTag(span: span, progress: progress, pill: pill)
                        }
                        // Tighter on top than the 14 it used to be: the time line above
                        // now carries that end of the card.
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        scheduleNotes(nestedRecords: nestedRecords, pill: pill)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The event's colour is carried by the glass itself rather than by a
                    // tint layer stacked under an opaque fill — one surface, so the card
                    // reads as coloured glass instead of paint behind frosting.
                    // Lighter than the old fill's tint layer needed to be: that one sat
                    // under an opaque white card, this one is the surface, and glass
                    // amplifies it wherever the sky behind is bright.
                    .glassEffect(
                        .regular.tint(pill.tint.opacity(scheme == .dark ? 0.18 : 0.12)),
                        in: .rect(cornerRadius: 16)
                    )
                    // Kept, unlike the neutral cards' border: this one is colour identity,
                    // not a stand-in for the edge highlight glass already draws.
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(pill.tint.opacity(0.32), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, cardGap)
                // The overlay is proposed exactly the card's size, so `maxHeight` here
                // resolves to the card's height — no negotiation, nothing to disagree.
                //
                // It hangs off the leading edge of the *padded* button, which already
                // starts one rail column in; the gap is inside that edge, not outside it,
                // so only the column has to be crossed back over.
                .overlay(alignment: .topLeading) {
                    schedulePill(schedule, pill: pill, progress: progress)
                        .offset(x: -(railWidth - (railWidth - schedulePillWidth) / 2))
                        .allowsHitTesting(false)
                }
            }
        }
        // Closed up while running, so the bar has only the connector's worth of gap to
        // cross before it reaches the marker.
        .padding(.bottom, progress == nil ? 14 : 4)
    }

    /// The coloured bar beside a schedule card, sized to whatever proposes it.
    ///
    /// Thick enough to carry the event's icon, but still inside the 24pt rail column
    /// every other marker uses, so the content beside it gives up no width for the
    /// extra weight.
    private func schedulePill(
        _ schedule: Schedule,
        pill: PillColorPair,
        progress: ScheduleProgress?
    ) -> some View {
        ZStack {
            if let progress {
                // Length tracks the card, but the fill tracks the clock — inside the bar
                // there is nothing for the duration to disagree with, which is what made
                // scaling its length unworkable.
                Self.pillShape
                    .fill(pill.tint.opacity(0.26))
                    .overlay(alignment: .top) {
                        GeometryReader { proxy in
                            Self.pillShape
                                .fill(pill.tint)
                                .frame(height: max(schedulePillWidth, proxy.size.height * progress.fraction))
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .shadow(color: pill.tint.opacity(0.42), radius: 6, y: 2)
            } else {
                Self.pillShape
                    // Full strength at the start, easing off towards the end, so the bar
                    // reads in the direction time runs.
                    .fill(
                        LinearGradient(
                            colors: [pill.tint, pill.tint.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: pill.tint.opacity(0.32), radius: 5, y: 2)
            }

            // Centred in the bar, so it reads as the badge of the block rather than a
            // marker for one of its ends. The gradient has faded a little by the middle,
            // hence the shadow carrying the contrast.
            Image(systemName: schedule.iconName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
        }
        .frame(width: schedulePillWidth)
        .frame(maxHeight: .infinity)
        // A running event carries the bar on down into the gap below its row so the now
        // marker's node lands on it. Drawn past the bounds, so joining the two costs no
        // layout height and the rows below keep their rhythm.
        .overlay(alignment: .bottom) {
            if progress != nil {
                Rectangle()
                    .fill(pill.tint.opacity(0.26))
                    .frame(width: schedulePillWidth, height: Self.nowConnectorHeight)
                    .offset(y: Self.nowConnectorHeight)
            }
        }
    }

    /// Bridges a running event's bar down to the now marker's node.
    private static let nowConnectorHeight: CGFloat = 16

    /// Named so the bar and the progress fill drawn inside it can never drift apart.
    ///
    /// A flatter radius was tried here first, on the theory that a capsule's curved ends
    /// were what made the bar look shorter than its card. They were not: the frames
    /// genuinely differed, which the overlay above now rules out, and squaring the ends
    /// only cost the shape its character.
    private static let pillShape = Capsule(style: .continuous)

    private func recordRow(_ record: Record) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(TimelinerDesign.subtle(for: scheme))
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().stroke(Color.white.opacity(0.7), lineWidth: 2)
                }
                .frame(width: railWidth, height: timeLineHeight)

            VStack(alignment: .leading, spacing: 6) {
                timeLine {
                    timeText(record.timeText)
                }

                // No longer one `Button` around the whole card: the photos inside it now
                // answer to their own taps. The card keeps its single meaning through a
                // tap gesture on the whole shape, which the cells' own gestures override
                // where they sit.
                VStack(alignment: .leading, spacing: 7) {
                    if !record.photos.isEmpty {
                        let photos = record.orderedPhotos
                        RecordPhotoGrid(photos: photos) { index in
                            photoViewer = PhotoViewerTarget(photos: photos, index: index)
                        }
                    }

                    Text(record.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .timelineCard(cornerRadius: 16, scheme: scheme)
                .contentShape(.rect(cornerRadius: 16))
                .onTapGesture { selectedRecord = record }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
            .padding(.leading, cardGap)
        }
        .padding(.bottom, 14)
    }

    private func todoBlock(_ items: [TodoItem]) -> some View {
        let completedCount = items.count(where: \.completed)
        let allDone = !items.isEmpty && completedCount == items.count
        return HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(TimelinerDesign.success)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().stroke(Color.white.opacity(0.7), lineWidth: 2)
                }
                .frame(width: railWidth, height: timeLineHeight)

            VStack(alignment: .leading, spacing: 6) {
                timeLine {
                    HStack(spacing: 6) {
                        // Green once the block is finished, because the time it shows
                        // has changed meaning: no longer when this was written down but
                        // when it was done.
                        timeText(
                            DateHelpers.format24Hour(from: todoBlockMoment(items)),
                            tint: allDone ? TimelinerDesign.success : nil
                        )
                        Text("할 일")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TimelinerDesign.muted(for: scheme))
                        Spacer(minLength: 8)
                        Text("\(completedCount)/\(items.count) 완료")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { todo in
                        TodoRowView(todo: todo)
                            .padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .timelineCard(cornerRadius: 16, scheme: scheme)
            }
            .padding(.leading, cardGap)
        }
        .padding(.bottom, 14)
    }

    /// How the rail stops.
    ///
    /// Each group sizes its own line, so past the last one the rail simply ended on a cut
    /// edge hanging in the middle of the screen. A day's records run out; they don't get
    /// severed. Fading the last stretch says the same thing without drawing a hard stop
    /// that looks like the view failed to finish rendering.
    private var railTerminus: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [TimelinerDesign.line(for: scheme), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: rail.lineWidth, height: 44)
            .offset(x: rail.lineLeadingX)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The rail is drawn per day group, and the marker belongs to no group — so without
    /// this the line stopped at the end of today's elapsed rows and picked up again
    /// below, leaving the timeline visibly cut in half at the one point it should read
    /// as continuous.
    private var railContinuation: some View {
        Rectangle()
            .fill(TimelinerDesign.line(for: scheme))
            .frame(width: rail.lineWidth)
            .offset(x: rail.lineLeadingX)
    }

    /// "27분 뒤 · 팀 주간 미팅", or nil when nothing is coming.
    ///
    /// Only schedules that have not started yet. One already running is not something you
    /// are waiting for, and its card already carries a progress bar and its own "남음";
    /// saying it twice in two different senses of "remaining" is worse than saying it
    /// once. All-day entries are out for a simpler reason — they have no start moment to
    /// count down to.
    ///
    /// Crossing midnight is free now that `startAt` is a real moment. Back when it was
    /// minutes-past-a-string, "the next one" could only ever mean "the next one today".
    private var nextScheduleCountdown: String? {
        let now = liveDate
        let next = schedules
            .compactMap { schedule -> (Date, String)? in
                guard !schedule.isAllDay, let start = schedule.startAt, start > now else { return nil }
                return (start, schedule.text)
            }
            .min { $0.0 < $1.0 }

        guard let (start, title) = next else { return nil }
        return "\(Self.waitLabel(from: now, to: start)) · \(title)"
    }

    /// How long until then, at the coarsest granularity that is still honest.
    ///
    /// Minutes stop being useful somewhere past a day: "1,847분 뒤" is a number nobody
    /// converts, and the answer someone actually wants that far out is "not today".
    private static func waitLabel(from now: Date, to start: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds < 60 { return "곧" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)분 뒤" }
        if minutes < 60 * 24 { return "\(DateHelpers.koreanDuration(minutes: minutes)) 뒤" }

        // Counted in calendar days rather than 24-hour blocks, so an event tomorrow
        // morning reads as "1일 뒤" whether it is 20 hours away or 30.
        let days = DateHelpers.calendar.dateComponents(
            [.day],
            from: DateHelpers.startOfDay(now),
            to: DateHelpers.startOfDay(start)
        ).day ?? 1
        return "\(max(1, days))일 뒤"
    }

    private var nowTint: Color { TimelinerDesign.now(for: scheme) }

    private var currentTimeMarker: some View {
        // Top-aligned rather than centred: the marker belongs to the "지금" line, and
        // centring would drift it down between that line and the countdown under it.
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                Circle()
                    .fill(nowTint.opacity(0.22))
                    .frame(width: 34, height: 34)
                Circle()
                    .stroke(nowTint.opacity(0.48), lineWidth: 2.5)
                    .frame(width: 28, height: 28)
                    .phaseAnimator(reduceMotion ? [.reset] : CurrentTimePulsePhase.allCases) { content, phase in
                        content
                            .scaleEffect(phase.scale)
                            .opacity(phase.opacity)
                    } animation: { phase in
                        phase.animation
                    }
                Circle()
                    .fill(nowTint)
                    .frame(width: 12, height: 12)
                    .shadow(color: nowTint.opacity(0.5), radius: 8)
            }
            .frame(width: railWidth, height: timeLineHeight)

            VStack(alignment: .leading, spacing: 3) {
                // Same shape as every other row — time first, then what it is — so the now
                // marker sits in the column of times rather than beside it.
                timeLine {
                    HStack(spacing: 8) {
                        timeText(
                            DateHelpers.format24Hour(from: liveDate),
                            tint: nowTint
                        )
                        Text("지금")
                            .font(.caption.bold())
                            .foregroundStyle(nowTint)
                        Rectangle()
                            .fill(nowTint.opacity(0.38))
                            .frame(height: 1.5)
                    }
                }

                // On its own line under the marker rather than trailing the rule. Sharing
                // the row meant the countdown and the line were competing for the same
                // width, and a long title left the rule as a stub — the one element whose
                // whole job is to read as a line across the day.
                if let countdown = nextScheduleCountdown {
                    // Plain text, not the marker's red. Red is what says "you are here";
                    // this line only says what is next, and colouring it the same made
                    // two different claims share one voice.
                    Text(countdown)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(TimelinerDesign.muted(for: scheme))
                        .lineLimit(1)
                }
            }
            .padding(.leading, cardGap)
        }
        .padding(.top, 2)
        .padding(.bottom, 20)
        .background(alignment: .topLeading) { railContinuation }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func searchResults(query: String) -> some View {
        let normalized = query.lowercased()
        let matchingSchedules = schedules.filter { $0.text.lowercased().contains(normalized) }
        let matchingRecords = records.filter { $0.text.lowercased().contains(normalized) }
        let matchingTodos = todos.filter { $0.text.lowercased().contains(normalized) }

        if matchingSchedules.isEmpty && matchingRecords.isEmpty && matchingTodos.isEmpty {
            ContentUnavailableView.search(text: query)
                .background(.clear)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    searchSectionTitle("일정", isVisible: !matchingSchedules.isEmpty)
                    ForEach(matchingSchedules) { schedule in
                        Button { selectedSchedule = schedule } label: {
                            ScheduleSearchResult(schedule: schedule)
                        }
                        .buttonStyle(.plain)
                    }

                    searchSectionTitle("할 일", isVisible: !matchingTodos.isEmpty)
                    ForEach(matchingTodos) { todo in
                        TodoSearchResult(todo: todo)
                    }

                    searchSectionTitle("기록", isVisible: !matchingRecords.isEmpty)
                    ForEach(matchingRecords) { record in
                        Button { selectedRecord = record } label: {
                            RecordSearchResult(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .background(.clear)
        }
    }

    @ViewBuilder
    private func searchSectionTitle(_ title: String, isVisible: Bool) -> some View {
        if isVisible {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    private var groupedDays: [GroupedDay] {
        var bucket: [Date: GroupedDay] = [:]
        let today = DateHelpers.startOfDay(liveDate)
        bucket[today] = GroupedDay(id: today, date: today, schedules: [], todos: [], records: [])
        for schedule in schedules {
            let key = DateHelpers.startOfDay(schedule.date)
            var group = bucket[key] ?? GroupedDay(id: key, date: key, schedules: [], todos: [], records: [])
            group.schedules.append(schedule)
            bucket[key] = group
        }
        for record in records {
            let key = DateHelpers.startOfDay(record.date)
            var group = bucket[key] ?? GroupedDay(id: key, date: key, schedules: [], todos: [], records: [])
            group.records.append(record)
            bucket[key] = group
        }
        for todo in todos {
            let key = DateHelpers.startOfDay(todo.date)
            var group = bucket[key] ?? GroupedDay(id: key, date: key, schedules: [], todos: [], records: [])
            group.todos.append(todo)
            bucket[key] = group
        }
        return bucket.values.sorted { $0.date < $1.date }
    }

    private func pastAndPresentGroups(from groups: [GroupedDay]) -> [GroupedDay] {
        let today = DateHelpers.startOfDay(liveDate)
        return groups.filter { $0.date <= today }
    }

    private func futureGroups(from groups: [GroupedDay]) -> [GroupedDay] {
        let today = DateHelpers.startOfDay(liveDate)
        return groups.filter { $0.date > today }
    }

    /// Splits a day's rows around the current minute.
    ///
    /// A schedule still running counts as elapsed — it started before now, so it belongs
    /// above the marker, which then lands directly beneath it.
    private func rows(for group: GroupedDay, portion: DayPortion) -> [TimelineRow] {
        let all = rows(for: group)
        guard portion != .whole else { return all }

        let nowMinutes = DateHelpers.minutesSinceMidnight(from: liveDate)
        return portion == .elapsed
            ? all.filter { $0.sortKey <= nowMinutes }
            : all.filter { $0.sortKey > nowMinutes }
    }

    private func rows(for group: GroupedDay) -> [TimelineRow] {
        let orderedSchedules = group.schedules.sorted { ($0.startMinutes ?? -1) < ($1.startMinutes ?? -1) }
        let orderedRecords = group.records.sorted { $0.occurredAt < $1.occurredAt }

        var nestedRecordIDs = Set<UUID>()
        var result: [TimelineRow] = []

        for schedule in orderedSchedules {
            let start = schedule.startMinutes ?? -1
            let end = schedule.endMinutes ?? start + 60
            let nested = orderedRecords.filter { record in
                guard !nestedRecordIDs.contains(record.id) else { return false }
                return start >= 0 && record.minutes >= start && record.minutes <= end
            }
            nestedRecordIDs.formUnion(nested.map(\.id))
            result.append(.schedule(schedule, nestedRecords: nested))
        }

        for record in orderedRecords where !nestedRecordIDs.contains(record.id) {
            result.append(.record(record))
        }
        if !group.todos.isEmpty {
            result.append(.todos(group.todos.sorted { $0.sortOrder < $1.sortOrder }))
        }
        return result.sorted { $0.sortKey < $1.sortKey }
    }

    /// nil for ordinary days — the weekday beside the date already covers those.
    private func relativeDayBadge(for date: Date) -> String? {
        if DateHelpers.sameDay(date, liveDate) { return "오늘" }
        let yesterday = DateHelpers.calendar.date(byAdding: .day, value: -1, to: liveDate) ?? liveDate
        let tomorrow = DateHelpers.calendar.date(byAdding: .day, value: 1, to: liveDate) ?? liveDate
        if DateHelpers.sameDay(date, yesterday) { return "어제" }
        if DateHelpers.sameDay(date, tomorrow) { return "내일" }
        return nil
    }

    /// Records made during the event.
    ///
    /// Nesting is by time containment — a record whose moment falls inside the event's
    /// span shows up here. Nothing links the two, which is why this works for events
    /// imported from a calendar and why moving a record's time quietly moves it out.
    ///
    /// Read-only on the timeline. Adding one lives in the detail sheet: an affordance on
    /// every card would put a button on rows the eye is meant to scan past, and the card
    /// stays a single tap target that opens the event.
    @ViewBuilder
    private func scheduleNotes(nestedRecords: [Record], pill: PillColorPair) -> some View {
        if !nestedRecords.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                // A rule, not a second card. Boxing these in their own rounded rectangle
                // with its own border put a card inside a card — two frames saying the
                // same thing, when all that is needed is a line marking where the event's
                // own details end and what happened during it begins.
                // All of this thread is drawn in `foreground` rather than `tint` for the
                // same reason the labels above are: it sits on glass tinted in its own
                // hue, where the saturated tint has nothing left to contrast against.
                Rectangle()
                    .fill(pill.foreground.opacity(0.25))
                    .frame(height: 1)
                    .padding(.bottom, 1)

                // Threaded, like the rail outside. Loose dots read as a bulleted list;
                // joining them says these happened one after another inside the event.
                // The connector is drawn per row so the ends stop at the outer dots
                // rather than overhanging the list.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nestedRecords.enumerated()), id: \.element.id) { index, record in
                        let isLast = index == nestedRecords.count - 1
                        HStack(alignment: .top, spacing: 9) {
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(index == 0 ? .clear : pill.foreground.opacity(0.35))
                                    .frame(width: 1.5, height: 6)
                                Circle()
                                    .fill(pill.foreground.opacity(0.9))
                                    .frame(width: 5, height: 5)
                                Rectangle()
                                    .fill(isLast ? .clear : pill.foreground.opacity(0.35))
                                    .frame(width: 1.5)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(width: 5)

                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(record.timeText)
                                    .font(.caption2.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(pill.foreground)

                                Text(record.text)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.bottom, isLast ? 0 : 9)
                        }
                    }
                }
            }
            // Shares the header's inset, so the notes sit in the same column as the title
            // rather than stepping in from it.
            .padding(.horizontal, 14)
            .padding(.bottom, 13)
        }
    }

    /// How long the event runs, in the card's top corner opposite its title.
    ///
    /// Bare text while it is only a fact about the event — inside a card that already has
    /// its own tinted fill and border, another filled chip was one container too many.
    /// A running event is a state rather than a fact, so that one keeps the capsule and
    /// the accent, and is the only thing in the card that changes while you look at it.
    @ViewBuilder
    private func durationTag(
        span: ScheduleSpan,
        progress: ScheduleProgress?,
        pill: PillColorPair
    ) -> some View {
        if let progress {
            Text(progress.remainingLabel)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14), in: Capsule())
        } else if let duration = span.duration {
            Text(duration)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(pill.foreground)
        }
    }

    /// Nil unless the event is running at this minute. `liveDate` ticks every 30 seconds,
    /// so the fill and the countdown keep themselves current without any extra timer.
    private func scheduleProgress(for schedule: Schedule) -> ScheduleProgress? {
        guard let start = schedule.startAt, let end = schedule.endAt,
              end > start, liveDate >= start, liveDate < end
        else { return nil }

        // Real moments now, so this comparison no longer has to assume both ends live on
        // the same day as `liveDate` — an event running past midnight measures correctly.
        let elapsed = liveDate.timeIntervalSince(start)
        let total = end.timeIntervalSince(start)
        let remaining = Int((total - elapsed) / 60)

        return ScheduleProgress(
            fraction: elapsed / total,
            remainingLabel: "\(DateHelpers.koreanDuration(minutes: remaining)) 남음"
        )
    }

    /// An all-day entry has no start to label and nothing to measure, and plenty of
    /// entries carry a start with no end — both fall out as nil rather than being
    /// invented, so the bar is only ever labelled at ends that exist.
    private func scheduleSpan(_ schedule: Schedule) -> ScheduleSpan {
        let start = schedule.startText ?? "종일"
        guard let startAt = schedule.startAt, let endAt = schedule.endAt else {
            return ScheduleSpan(start: start, end: nil, duration: nil)
        }

        let minutes = Int(endAt.timeIntervalSince(startAt) / 60)
        return ScheduleSpan(
            start: start,
            end: schedule.endText,
            duration: minutes > 0 ? DateHelpers.koreanDuration(minutes: minutes) : nil
        )
    }

}

private struct ScheduleSearchResult: View {
    @Environment(\.colorScheme) private var scheme
    let schedule: Schedule

    var body: some View {
        let pill = PillColors.colors(for: schedule.colorTheme, dark: scheme == .dark)
        HStack(spacing: 12) {
            Capsule()
                .fill(pill.tint)
                .frame(width: 5, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.text).font(.subheadline.bold())
                Text(DateHelpers.koreanDateLabel(schedule.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(schedule.startText ?? "종일")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }
}

private struct TodoSearchResult: View {
    let todo: TodoItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(todo.completed ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(todo.text)
                    .strikethrough(todo.completed)
                Text(DateHelpers.koreanDateLabel(todo.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }
}

private struct RecordSearchResult: View {
    let record: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.text)
                .font(.subheadline)
                .lineLimit(3)
            Text("\(DateHelpers.koreanDateLabel(record.date)) · \(record.timeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 16)
    }
}
