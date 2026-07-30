import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private struct CollapseTransform: Equatable {
    var scale: CGSize
    var offsetY: CGFloat
    var anchor: UnitPoint

    /// Used when the pill's reported frame can't be trusted: grow up out of the card's
    /// own bottom edge, which is where the bar sits anyway.
    static let fromBottomEdge = CollapseTransform(
        scale: CGSize(width: 0.96, height: 0.2),
        offsetY: 0,
        anchor: .bottom
    )
}

/// `collapsed` and `exiting` share a geometry but not an appearance, and a plain
/// bool could not tell them apart — which let a stray layout pass during dismissal
/// re-trigger the reveal.
private enum ComposerPhase {
    case collapsed
    case expanded
    case exiting
}

/// The native control, wrapped only so `selectedSegmentTintColor` can follow the
/// selection — SwiftUI's `.tint()` does not reach the segmented indicator, and the
/// appearance proxy only applies at control creation, so neither can recolour it live.
///
/// Segments carry real SF Symbols via `setImage`, not text rendered into a bitmap, so
/// nothing here is baked: the control keeps its own glass indicator and the grab, drag
/// and snap behaviour that comes with it.
private struct NativeTypeSegments: UIViewRepresentable {
    @Binding var selection: QuickEntryType
    let selectedTint: UIColor

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(frame: .zero)
        for (index, type) in QuickEntryType.allCases.enumerated() {
            // There is no per-segment accessibility setter; the control reads the
            // label off the image it was given.
            let symbol = UIImage(systemName: type.systemImage)
            symbol?.accessibilityLabel = type.title
            control.insertSegment(with: symbol, at: index, animated: false)
        }
        control.selectedSegmentIndex = Self.index(of: selection)
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)),
            for: .valueChanged
        )
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection

        let index = Self.index(of: selection)
        if control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
        }
        control.selectedSegmentTintColor = selectedTint
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    private static func index(of type: QuickEntryType) -> Int {
        QuickEntryType.allCases.firstIndex(of: type) ?? 0
    }

    final class Coordinator: NSObject {
        var selection: Binding<QuickEntryType>

        init(selection: Binding<QuickEntryType>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: UISegmentedControl) {
            let all = QuickEntryType.allCases
            guard all.indices.contains(sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = all[sender.selectedSegmentIndex]
        }
    }
}

private struct ComposerCardChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

/// Stage two of the composer. Presented in a `fullScreenCover` with a clear
/// background rather than laid into the tab view's own hierarchy: the cover gets
/// its own keyboard avoidance, so raising the keyboard can't resize the timeline
/// underneath and knock its scroll metrics (and the upcoming-list reveal) around.
struct RecordComposerView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: [SortDescriptor(\TodoItem.sortOrder, order: .forward)])
    private var todos: [TodoItem]

    @Binding var draft: RecordInputDraft
    /// The text being typed, held here rather than in `draft`.
    ///
    /// `draft` lives in `RootView`'s `@State`, so writing to it on every keystroke made
    /// the whole app's root — the tab view, the bottom accessory, everything behind this
    /// cover — re-evaluate once per character. Nothing out there needs to see the text
    /// mid-sentence: the pill that displays it is underneath a full-screen cover, and the
    /// only readers that matter are the submit button and the save itself. So the typing
    /// stays in here and is handed back when the composer closes.
    @State private var text: String = ""
    @Binding var isPresented: Bool
    /// Screen rect of the stage-one pill. The card starts life scaled down onto it.
    var pillFrame: CGRect = .zero
    var onRecordAdded: (() -> Void)?

    @State private var errorMessage: String?
    @State private var savePulse = 0
    @State private var phase: ComposerPhase = .collapsed
    @State private var cardFrame: CGRect = .zero
    @State private var frozenCollapse: CollapseTransform?
    @FocusState private var inputFocused: Bool

    /// Keyboard retraction runs about a quarter second, so the shrink is matched to
    /// it — both motions finish together instead of one trailing the other.
    private static let exitDuration: TimeInterval = 0.24

    private var isExpanded: Bool { phase == .expanded }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .opacity(isExpanded ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityLabel("닫기")
                .accessibilityAddTraits(.isButton)

            card
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    cardFrame = frame
                    revealIfReady()
                }
                // Layout frame is unaffected by these transforms, so measuring above
                // stays stable while the morph runs.
                .scaleEffect(
                    x: isExpanded ? 1 : collapse.scale.width,
                    y: isExpanded ? 1 : collapse.scale.height,
                    anchor: collapse.anchor
                )
                .offset(y: isExpanded ? 0 : collapse.offsetY)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sensoryFeedback(.success, trigger: savePulse)
        .alert("저장 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var card: some View {
        cardContent
            .opacity(isExpanded ? 1 : 0)
            .animation(contentFade, value: phase)
            .padding(16)
            .modifier(ComposerCardChrome())
            // The card has to swallow every touch that lands on it. Its glass chrome
            // is decoration and doesn't hit-test, and the gaps between controls — the
            // 14pt under the segmented control, the inner padding — hold no view of
            // their own, so a tap there used to fall straight through to the dim
            // layer behind and close the composer. Focusing the field is the sensible
            // thing to do with a tap on empty card space; inner controls still win.
            .contentShape(.rect)
            .onTapGesture { inputFocused = true }
            // The chrome needs its own fade on the way out. Without it the shrink
            // ends on a fully opaque glass capsule that the cover then deletes in a
            // single frame — which is the blink. Driven by dismiss()'s withAnimation,
            // so entry keeps the card solid from the first frame.
            .opacity(phase == .exiting ? 0 : 1)
    }

    /// Asymmetric on purpose. Growing: the shape opens first and the controls catch
    /// up, so the squashed start state is never legible. Shrinking: the controls go
    /// first and fast, otherwise they stay readable while being crushed vertically.
    private var contentFade: Animation? {
        guard !reduceMotion else { return nil }
        return isExpanded
            ? .easeOut(duration: 0.18).delay(0.1)
            : .easeIn(duration: 0.08)
    }

    private var collapse: CollapseTransform {
        // Dropping focus retracts the keyboard, which re-lays out the card and moves
        // `cardFrame` — recomputing mid-exit would drag the target out from under the
        // animation. The snapshot taken at dismissal keeps it still.
        frozenCollapse ?? liveCollapse
    }

    private var liveCollapse: CollapseTransform {
        // The bar lives below the composer, always. On the very first presentation the
        // accessory has not been positioned yet and reports itself at the top of the
        // screen (y ≈ 1), which made the card start ~765pt high and sail downwards.
        // Failing that invariant means the frame is not usable yet.
        guard cardFrame.width > 0, cardFrame.height > 0,
              pillFrame.height > 0,
              pillFrame.midY > cardFrame.midY
        else {
            return .fromBottomEdge
        }

        return CollapseTransform(
            scale: CGSize(
                width: min(1, pillFrame.width / cardFrame.width),
                height: min(1, pillFrame.height / cardFrame.height)
            ),
            offsetY: pillFrame.midY - cardFrame.midY,
            anchor: .center
        )
    }

    /// Only `.collapsed` may reveal. Dismissal dropping the keyboard triggers another
    /// layout pass, and this used to read as "not yet revealed" and bounce the card
    /// back open mid-exit.
    private func revealIfReady() {
        guard phase == .collapsed, cardFrame.height > 0 else { return }
        // Picks up whatever the pill was still holding from a cancelled sitting.
        text = draft.inputText
        withAnimation(reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.82)) {
            phase = .expanded
        }
        inputFocused = true
    }

    private func dismiss() {
        guard phase == .expanded else { return }

        guard !reduceMotion else {
            inputFocused = false
            phase = .exiting
            closeWithoutCoverTransition()
            return
        }

        frozenCollapse = liveCollapse
        inputFocused = false

        // easeOut rather than a spring: a spring's settling tail outlives the window
        // the cover is torn down in, which reads as the card being snatched away.
        withAnimation(.easeOut(duration: Self.exitDuration)) {
            phase = .exiting
        }
        // A frame of slack, so the card is provably invisible before the cover goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration + 0.02) {
            closeWithoutCoverTransition()
        }
    }

    /// The cover's own slide would fight the morph, so it is dropped instantly and
    /// the shrink above carries the exit.
    private func closeWithoutCoverTransition() {
        // Handed back on the way out so a cancelled sentence is still in the pill when
        // you come back to it — the one thing the root actually needed from the typing.
        draft.inputText = text
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresented = false }
    }

    /// The composer takes its accent from the entry type, so the colour that names the
    /// type in the bar carries straight through into the open composer.
    private var pill: PillColorPair {
        PillColors.colors(for: draft.entryType.colorTheme, dark: scheme == .dark)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Icon-only, because that is the shape the native control actually supports:
            // it is the only way to get the real Liquid Glass indicator — grab-to-lift,
            // drag-to-scrub with refraction, release-to-snap — none of which is exposed
            // as public API for a custom view. The type is still named in words by the
            // placeholder below.
            NativeTypeSegments(
                selection: $draft.entryType,
                selectedTint: UIColor(pill.tint.opacity(scheme == .dark ? 0.55 : 0.3))
            )
            .frame(height: 32)

            TextField(draft.entryType.placeholder, text: $text, axis: .vertical)
                .font(.callout)
                .lineLimit(3...9)
                .textInputAutocapitalization(.never)
                .tint(pill.tint)
                .focused($inputFocused)
                .frame(minHeight: 70, alignment: .topLeading)

            if draft.entryType == .record, !draft.photos.isEmpty {
                photoStrip
            }

            timeFields

            actionRow
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: draft.entryType)
    }

    /// A strip rather than the grid the timeline draws: here the photos are a list being
    /// edited, and each one needs its own reachable remove button. Ordering is the
    /// picker's, which is the order they will be stored and shown in.
    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.photos) { photo in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 92, height: 92)
                            .clipShape(.rect(cornerRadius: 12))

                        Button {
                            // Taken out of the picker's selection, not out of `photos`:
                            // the reconciliation below follows from that, and dropping
                            // only the loaded copy would leave the picker still holding it.
                            draft.selectedPhotoItems.removeAll { $0 == photo.item }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .accessibilityLabel("사진 제거")
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 94)
    }

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            DatePicker(
                draft.entryType == .schedule ? "시작" : "시간",
                selection: $draft.pickedDate,
                displayedComponents: [.date, .hourAndMinute]
            )

            if draft.entryType == .schedule {
                DatePicker(
                    "종료",
                    selection: $draft.pickedEndDate,
                    in: draft.pickedDate...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(TimelinerDesign.muted(for: scheme))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if draft.entryType == .record {
                PhotosPicker(
                    selection: selectedPhotoItems,
                    maxSelectionCount: RecordInputDraft.maxPhotoCount,
                    selectionBehavior: .ordered,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: draft.photos.isEmpty ? "photo.badge.plus" : "photo.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(pill.foreground)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(pill.tint.opacity(scheme == .dark ? 0.22 : 0.12)))

                        if draft.photos.count > 1 {
                            Text("\(draft.photos.count)")
                                .font(.system(size: 10, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Circle().fill(pill.tint))
                                .offset(x: 3, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(draft.photos.isEmpty ? "사진 첨부" : "사진 변경")
                .onChange(of: draft.selectedPhotoItems) { _, items in
                    syncPhotos(with: items)
                }
            }

            Spacer(minLength: 0)

            Button("취소", action: dismiss)
                .font(.callout.weight(.semibold))
                .foregroundStyle(TimelinerDesign.muted(for: scheme))
                .buttonStyle(.plain)

            Button(action: addItem) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    // Disabled keeps the type's colour rather than going neutral grey,
                    // so the button reads as "this will save a 기록/할 일/일정" even
                    // before there is anything to save. Legibility carries the state:
                    // solid fill with a white glyph when armed, faded with a dimmed
                    // glyph when not.
                    .foregroundStyle(canSubmit ? .white : pill.foreground.opacity(0.55))
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(pill.tint.opacity(canSubmit ? 1 : 0.24))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("\(draft.entryType.title) 추가")
        }
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (draft.entryType == .record && !draft.photos.isEmpty)
    }

    private var selectedPhotoItems: Binding<[PhotosPickerItem]> {
        Binding(
            get: { draft.selectedPhotoItems },
            set: { draft.selectedPhotoItems = $0 }
        )
    }

    /// Reconciles the loaded photos against the picker's selection instead of reloading
    /// the lot on every change — removing one of nine should not make the other eight
    /// blink out and decode again.
    private func syncPhotos(with items: [PhotosPickerItem]) {
        draft.photos.removeAll { !items.contains($0.item) }

        let loaded = Set(draft.photos.map(\.item))
        let arrivals = items.filter { !loaded.contains($0) }
        guard !arrivals.isEmpty else {
            reorderPhotos(by: items)
            return
        }

        Task {
            for item in arrivals {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)
                    else { continue }
                    // Re-checked after the await: the picker may have dropped this one
                    // while it was loading, and appending it now would resurrect it.
                    guard draft.selectedPhotoItems.contains(item) else { continue }
                    draft.photos.append(DraftPhoto(item: item, data: data, image: image))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            reorderPhotos(by: draft.selectedPhotoItems)
        }
    }

    /// The picker's order is the one the user chose, so it is the one that gets stored.
    private func reorderPhotos(by items: [PhotosPickerItem]) {
        draft.photos.sort {
            (items.firstIndex(of: $0.item) ?? .max) < (items.firstIndex(of: $1.item) ?? .max)
        }
    }

    private func addItem() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }

        // Held so the todo can be pushed to 미리알림 once the local save has gone through.
        var newTodo: TodoItem?

        switch draft.entryType {
        case .record:
            let record = Record(
                occurredAt: draft.pickedDate,
                text: trimmed.isEmpty ? "사진" : trimmed
            )
            modelContext.insert(record)
            for (index, photo) in draft.photos.enumerated() {
                let attachment = RecordPhoto(data: photo.data, sortOrder: index)
                attachment.record = record
                modelContext.insert(attachment)
            }

        case .todo:
            let day = DateHelpers.startOfDay(draft.pickedDate)
            let nextSortOrder = todos
                .filter { DateHelpers.sameDay($0.date, day) }
                .map(\.sortOrder)
                .max()
                .map { $0 + 1 } ?? 0
            let todo = TodoItem(date: day, text: trimmed, sortOrder: nextSortOrder)
            modelContext.insert(todo)
            newTodo = todo

        case .schedule:
            let endDate = max(draft.pickedEndDate, draft.pickedDate.addingTimeInterval(3600))
            modelContext.insert(Schedule(
                date: DateHelpers.startOfDay(draft.pickedDate),
                startAt: draft.pickedDate,
                endAt: endDate,
                text: trimmed,
                calendarName: "타임라이너",
                colorTheme: .blue,
                iconName: "calendar"
            ))
        }

        do {
            try modelContext.save()
            if let newTodo {
                // After the save, and not waited on: the composer is already closing.
                EventKitSyncManager.shared.exportNewTodo(newTodo, context: modelContext)
            }
            draft.reset()
            text = ""
            savePulse += 1
            onRecordAdded?()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
