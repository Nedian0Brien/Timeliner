import PhotosUI
import SwiftData
import SwiftUI
import UIKit

enum QuickEntryType: String, CaseIterable, Identifiable {
    case record
    case todo
    case schedule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "기록"
        case .todo: return "할 일"
        case .schedule: return "일정"
        }
    }

    var systemImage: String {
        switch self {
        case .record: return "square.and.pencil"
        case .todo: return "checkmark.circle"
        case .schedule: return "calendar"
        }
    }

    var placeholder: String {
        switch self {
        case .record: return "지금 이 순간을 기록하세요"
        case .todo: return "새로운 할 일을 입력하세요"
        case .schedule: return "새로운 일정을 입력하세요"
        }
    }

    /// Reuses the existing pill palette rather than inventing colours. Records hold
    /// blue as the default type, which pushes schedules to orange — purple would sit
    /// too close to the blue-to-purple night sky behind the bar to stay legible.
    var colorTheme: ScheduleColorTheme {
        switch self {
        case .record: return .blue
        case .todo: return .emerald
        case .schedule: return .orange
        }
    }

    /// Wraps around, so the leading icon can cycle all three by repeated taps.
    var next: QuickEntryType {
        let ordered = Self.allCases
        let index = ordered.firstIndex(of: self) ?? 0
        return ordered[(index + 1) % ordered.count]
    }

    var previous: QuickEntryType {
        let ordered = Self.allCases
        let index = ordered.firstIndex(of: self) ?? 0
        return ordered[(index - 1 + ordered.count) % ordered.count]
    }
}

private struct RecordInputChrome: ViewModifier {
    let usesSystemAccessoryChrome: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesSystemAccessoryChrome {
            content
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .padding(.horizontal, 10)
        } else if #available(iOS 26.0, *) {
            content
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        } else {
            content
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }
}

/// A picked photo that has finished loading, held together with the picker item it came
/// from so removing one takes the other out with it.
struct DraftPhoto: Identifiable {
    let item: PhotosPickerItem
    let data: Data
    let image: UIImage

    var id: PhotosPickerItem { item }
}

struct RecordInputDraft {
    /// Enough for the grid to stay legible and for one record's storage to stay
    /// predictable. The picker enforces it, so there is no over-count to handle.
    static let maxPhotoCount = 9

    var inputText = ""
    var entryType: QuickEntryType = .record
    var pickedDate = Date()
    var pickedEndDate = Date().addingTimeInterval(3600)
    /// The picker's own selection, and the source of truth for what is attached — the
    /// loaded `photos` are reconciled against it rather than tracked separately.
    var selectedPhotoItems: [PhotosPickerItem] = []
    var photos: [DraftPhoto] = []

    mutating func reset() {
        let retainedType = entryType
        self = RecordInputDraft()
        entryType = retainedType
    }
}

/// The label sliding alongside the current one during a swipe.
private struct EntryNeighbour {
    var type: QuickEntryType
    /// `+1` when it arrives from the right, which is what a leftward drag pulls in.
    var side: CGFloat
}

/// A swipe that has been let go of and is animating to rest.
private struct EntryRelease {
    var neighbour: EntryNeighbour
    /// Whether the neighbour is travelling to centre or being sent back out.
    var commits: Bool
}

/// Stage one of the composer. Deliberately holds no `TextField`: this sits in the
/// tab view's bottom accessory, which the system resizes and minimises on scroll,
/// and a focusable field in there fights the keyboard avoidance. Tapping hands off
/// to `RecordComposerView`, which owns the actual editing.
struct RecordInputBar: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the labels have been dragged from centre. Drives the whole gesture:
    /// the text rides it, the icon fades against it, and the release animates it home.
    @State private var dragX: CGFloat = 0
    /// Finger is down and the drag has locked to the horizontal axis.
    @State private var tracking = false
    /// Set for the length of the release animation, and the reason the neighbour label
    /// stays on screen after the finger has gone.
    @State private var release: EntryRelease?
    @State private var selectionPulse = 0
    @State private var textWindowWidth: CGFloat = 240

    /// Below this the drag is not recognised at all, so taps still reach the buttons.
    private static let activationSlack: CGFloat = 14
    /// Past this on release the type changes; a fast flick clears it on velocity alone.
    private static let commitDistance: CGFloat = 56
    private static let iconFadeDistance: CGFloat = 30
    /// A 36pt glyph plus the 8pt gap beside it.
    private static let glyphSlot: CGFloat = 44
    private static let settle: Animation = .spring(response: 0.34, dampingFraction: 0.86)
    private static let recenter: Animation = .spring(response: 0.3, dampingFraction: 0.82)

    let draft: RecordInputDraft
    private let usesSystemAccessoryChrome: Bool
    let onTap: () -> Void
    /// Type changes stay separate from `onTap`, so the leading icon and a horizontal
    /// swipe switch in place instead of opening the composer.
    let onSelectType: (QuickEntryType) -> Void
    /// Screen rect of the pill, so the composer can grow out of exactly this spot.
    var onFrameChange: ((CGRect) -> Void)?

    init(
        draft: RecordInputDraft,
        usesSystemAccessoryChrome: Bool = false,
        onTap: @escaping () -> Void,
        onSelectType: @escaping (QuickEntryType) -> Void,
        onFrameChange: ((CGRect) -> Void)? = nil
    ) {
        self.draft = draft
        self.usesSystemAccessoryChrome = usesSystemAccessoryChrome
        self.onTap = onTap
        self.onSelectType = onSelectType
        self.onFrameChange = onFrameChange
    }

    // Two tap targets now, so the bar can no longer be one large button.
    var body: some View {
        ZStack(alignment: .leading) {
            // Spans the whole bar and sits under the chrome, so the pill's own edge is
            // what crops the labels. Laid out between the icon and the send glyph
            // instead, the crop would fall a glyph's width in from either end and the
            // text would disappear into an empty gap partway through the scroll.
            previewWindow

            HStack(spacing: 8) {
                typeButton

                Button(action: onTap) {
                    HStack(spacing: 8) {
                        // The text is a layer below; this side only holds the glyph and
                        // the tap target that opens the composer.
                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle().fill(hasDraft ? Color.accentColor : Color.secondary.opacity(0.28))
                            )
                    }
                    // Stated rather than inherited from the glyph. Hiding the glyph while
                    // the tab bar was minimised left this label with nothing that had a
                    // width, the frame collapsed, and `contentShape` had a zero-sized rect
                    // to work with — the whole bar stopped responding to taps.
                    .frame(maxWidth: .infinity)
                    // Without this the space beside the glyph is dead.
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(draft.entryType.title) 입력 열기")
                .accessibilityValue(draft.inputText)
                .accessibilityHint(hasDraft ? "작성 중인 내용이 있습니다" : "")
            }
        }
        // No blanket `.animation(value: draft.entryType)` here: a swipe hands the type
        // over at the very end with animations off, and a subtree-wide animation would
        // take hold of that handover. The two places that need it drive their own.
        //
        // Pulsed rather than triggered on the type itself, because a swipe only commits
        // the type once the animation lands — the tick belongs at the release.
        .sensoryFeedback(.selection, trigger: selectionPulse)
        .modifier(RecordInputChrome(usesSystemAccessoryChrome: usesSystemAccessoryChrome))
        .highPriorityGesture(typeSwipe)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            onFrameChange?(frame)
        }
    }

    /// The window the labels scroll inside. The pill's own edge does the cropping, so
    /// the outgoing text leaves and the incoming one arrives the way a paged carousel
    /// moves rather than one label swapping for another.
    private var previewWindow: some View {
        ZStack(alignment: .leading) {
            previewLabel(for: draft.entryType)
                .offset(x: dragX)

            // The type being dragged towards, already on its way in. Without it the
            // window empties out mid-swipe and the gesture reads as a wipe.
            if let neighbour {
                previewLabel(for: neighbour.type)
                    .offset(x: dragX + neighbour.side * slideDistance)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            textWindowWidth = width
        }
        // Offsets alone would let the labels spill out past the pill.
        .clipped()
        // Purely the scrolling surface — the chrome above owns every touch, and the
        // button up there already announces what this text says.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The insets are what keep the text clear of the icon and the send glyph at rest.
    /// They travel with the label, so mid-scroll the text runs the full width of the
    /// pill and passes behind both.
    private func previewLabel(for type: QuickEntryType) -> some View {
        Text(draft.inputText.isEmpty ? type.placeholder : draft.inputText)
            .font(.callout)
            .foregroundStyle(draft.inputText.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.glyphSlot)
            .padding(.trailing, Self.glyphSlot)
    }

    /// How far a label travels to clear the window. Measured, so the outgoing text is
    /// fully cropped by the time the incoming one lands on centre.
    private var slideDistance: CGFloat { max(textWindowWidth, 120) }

    /// Derived while the finger is down, remembered once it lifts. Keeping it alive
    /// through the release is what lets the pair finish travelling together.
    private var neighbour: EntryNeighbour? {
        if let release { return release.neighbour }
        guard tracking, dragX != 0 else { return nil }
        return dragX < 0
            ? EntryNeighbour(type: draft.entryType.next, side: 1)
            : EntryNeighbour(type: draft.entryType.previous, side: -1)
    }

    /// The glyph belongs to whichever label is nearest centre, so it names the type you
    /// are actually looking at rather than the one you started from.
    private var glyphType: QuickEntryType {
        guard let neighbour, abs(dragX) > slideDistance / 2 else { return draft.entryType }
        return neighbour.type
    }

    /// High priority, or the inner buttons claim the touch first and a swipe just
    /// opens the composer. `minimumDistance` keeps taps reaching those buttons.
    private var typeSwipe: some Gesture {
        DragGesture(minimumDistance: Self.activationSlack)
            .onChanged { value in
                guard !reduceMotion else { return }
                if !tracking {
                    // Axis is settled once, at pick-up. Re-testing every frame would let
                    // a diagonal drag flicker in and out of tracking.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    // A release still in the air is landed now, rather than left to fire
                    // its completion in the middle of this new drag.
                    finishRelease()
                    tracking = true
                }
                dragX = tracked(value.translation.width)
            }
            .onEnded { value in
                guard !reduceMotion else {
                    let horizontal = value.translation.width
                    guard abs(horizontal) > abs(value.translation.height) else { return }
                    selectionPulse += 1
                    onSelectType(horizontal < 0 ? draft.entryType.next : draft.entryType.previous)
                    return
                }
                guard tracking else { return }
                beginRelease(
                    offset: tracked(value.translation.width),
                    predicted: tracked(value.predictedEndTranslation.width)
                )
            }
    }

    /// The gesture only fires once the finger has already moved `activationSlack`, so
    /// the raw translation starts out that far along. Subtracting it stops the text
    /// jumping the instant the drag is recognised.
    private func tracked(_ raw: CGFloat) -> CGFloat {
        let magnitude = max(0, abs(raw) - Self.activationSlack)
        return raw < 0 ? -magnitude : magnitude
    }

    /// Lets the pair finish the travel the finger started, and only swaps the type once
    /// it has landed.
    ///
    /// Changing the type up front cannot work: setting `dragX` to the far side and then
    /// animating it back to zero in the same call collapses into one update, the far
    /// side never renders, and the whole thing lands in a single frame — the jump. Here
    /// nothing is handed over until the animation reports itself done, at which point
    /// the two labels are pixel-identical and the swap costs no motion at all.
    private func beginRelease(offset: CGFloat, predicted: CGFloat) {
        guard let neighbour else {
            tracking = false
            withAnimation(Self.recenter) { dragX = 0 }
            return
        }

        // A flick that never travelled far still counts, if it was thrown hard enough.
        let commits = abs(offset) >= Self.commitDistance
            || abs(predicted) >= Self.commitDistance * 2.2

        // `release` takes over from `tracking` as what keeps the neighbour on screen.
        release = EntryRelease(neighbour: neighbour, commits: commits)
        tracking = false
        if commits { selectionPulse += 1 }

        withAnimation(commits ? Self.settle : Self.recenter) {
            dragX = commits ? -neighbour.side * slideDistance : 0
        } completion: {
            finishRelease()
        }
    }

    /// Hands the landed position back to `draft.entryType` at zero offset. Nothing moves:
    /// the label that ends up on screen is the one already sitting there.
    private func finishRelease() {
        guard let release else { return }

        var handover = Transaction()
        handover.disablesAnimations = true
        withTransaction(handover) {
            if release.commits { onSelectType(release.neighbour.type) }
            dragX = 0
            self.release = nil
        }
    }

    /// Bare glyph, no container. Any shape behind it read as a second bubble sitting
    /// inside the pill. The 36pt frame stays for the tap target even though nothing
    /// is drawn there.
    ///
    /// `resizable().scaledToFit()` in a fixed box is what keeps the centre still while
    /// cycling: sized by font, each symbol is laid out in its own text box — pencil,
    /// circle and calendar have different bounding boxes and ascenders, so the glyph
    /// appeared to wander. Fitting each one into the same square normalises that.
    private var typeButton: some View {
        let pill = PillColors.colors(for: glyphType.colorTheme, dark: scheme == .dark)
        return Button {
            selectionPulse += 1
            // Its own animation, now that the bar has no subtree-wide one to inherit.
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                onSelectType(draft.entryType.next)
            }
        } label: {
            Image(systemName: glyphType.systemImage)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(pill.foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 21, height: 21)
                // The glyph names a settled type, so it steps aside for as long as the
                // labels are between two of them. Tied to `dragX` rather than toggled,
                // so it follows the finger out and rides the release spring back in.
                .opacity(iconReveal)
                .scaleEffect(0.7 + 0.3 * iconReveal)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("입력 유형: \(draft.entryType.title)")
        .accessibilityHint("두 번 탭하면 다음 유형으로 바뀝니다. 좌우로 스와이프해도 바뀝니다")
    }

    /// Measured against the nearer of the two resting positions — centred, or a full
    /// slide away — so the glyph is back at full strength by the time either label
    /// lands, whichever way the release goes. Keyed off the same `dragX` the labels
    /// use, so it can never finish out of step with them.
    private var iconReveal: Double {
        guard neighbour != nil else { return 1 }
        let settled = min(abs(dragX), abs(slideDistance - abs(dragX)))
        return Double(max(0, 1 - settled / Self.iconFadeDistance))
    }

    private var hasDraft: Bool {
        !draft.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.photos.isEmpty
    }
}

/// The bar as the tab view's bottom accessory, where the system supplies the chrome.
///
/// It used to shed the send glyph when the tab bar minimised, on the reasoning that the
/// inline pill is narrower. That cost more than it bought: the glyph was the only thing
/// in the tap target with a width, so losing it left the whole bar untappable, and with
/// it the only visible sign that the bar does anything.
@available(iOS 26.0, *)
struct RecordInputAccessory: View {
    let draft: RecordInputDraft
    let onTap: () -> Void
    let onSelectType: (QuickEntryType) -> Void
    var onFrameChange: ((CGRect) -> Void)?

    var body: some View {
        RecordInputBar(
            draft: draft,
            usesSystemAccessoryChrome: true,
            onTap: onTap,
            onSelectType: onSelectType,
            onFrameChange: onFrameChange
        )
    }
}

/// Holds the pill's screen rect outside the view graph.
///
/// Writing this into `@State` deadlocks the UI: the accessory reports its frame,
/// the state write re-evaluates the owning view, that rebuilds the accessory, which
/// reports again — the main thread pins at 100% and the app freezes. A reference the
/// view merely holds lets geometry land without invalidating anything, and the
/// composer reads it once at presentation.
@MainActor
final class PillFrameBox {
    var rect: CGRect = .zero
}
