import SwiftUI

/// Which photo of which record the viewer should open on.
struct PhotoViewerTarget: Identifiable {
    let photos: [RecordPhoto]
    let index: Int

    /// The photo it opens on, so re-tapping a different cell presents again rather than
    /// being taken for the same presentation.
    var id: UUID { photos.indices.contains(index) ? photos[index].id : UUID() }
}

/// The photos of one record, full screen, one per page.
///
/// Fitted rather than filled: the grid crops to make a mosaic, and this is the place
/// that undoes that — the whole reason to open a photo is to see the parts the mosaic
/// cut off.
struct PhotoViewerView: View {
    let target: PhotoViewerTarget

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    /// How far the dismiss drag has pulled the content down.
    @State private var dismissOffset: CGSize = .zero
    /// Set by whichever page is zoomed in. The dismiss drag stands down while it is
    /// true, because at that point a drag means "move around inside this photo".
    @State private var isZoomed = false

    private static let dismissDistance: CGFloat = 130

    init(target: PhotoViewerTarget) {
        self.target = target
        _index = State(initialValue: target.index)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(target.photos.enumerated()), id: \.element.id) { offset, photo in
                    ZoomablePhoto(photo: photo, isZoomed: $isZoomed)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(dismissOffset)
            .scaleEffect(dragScale)
        }
        // Simultaneous rather than exclusive: the page view owns horizontal drags and
        // this only ever acts on vertical ones, so the two do not have to be arbitrated.
        .simultaneousGesture(dismissDrag)
        .overlay(alignment: .top) { chrome }
        .statusBarHidden()
    }

    /// Fades with the pull, so the timeline showing through says the drag is going
    /// somewhere before it is finished.
    private var backdropOpacity: Double {
        guard dismissOffset.height > 0 else { return 1 }
        return max(0.15, 1 - Double(dismissOffset.height / (Self.dismissDistance * 2.4)))
    }

    private var dragScale: CGFloat {
        guard dismissOffset.height > 0 else { return 1 }
        return max(0.86, 1 - dismissOffset.height / 1_400)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
                // Downward only, and only once the drag has committed to the vertical.
                // Otherwise a lazy horizontal swipe would drag the page off its own axis.
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width)
                else { return }
                dismissOffset = CGSize(width: value.translation.width / 3, height: value.translation.height)
            }
            .onEnded { value in
                guard !isZoomed else { return }
                let thrown = value.predictedEndTranslation.height > Self.dismissDistance * 2
                if dismissOffset.height > Self.dismissDistance || thrown {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dismissOffset = .zero
                    }
                }
            }
    }

    private var chrome: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("닫기")

            Spacer()

            if target.photos.count > 1 {
                Text("\(index + 1) / \(target.photos.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.4)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Fades out of the way as the photo is pulled down, rather than riding along on
        // top of a photo that is leaving.
        .opacity(dismissOffset.height > 0 ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: dismissOffset.height > 0)
    }
}

/// One photo that can be pinched, panned and double-tapped.
private struct ZoomablePhoto: View {
    let photo: RecordPhoto
    /// Reported upwards so the viewer knows to leave drags alone.
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxScale: CGFloat = 4
    private static let doubleTapScale: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            RecordPhotoView(photoID: photo.id, photoData: photo.data, contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(.rect)
                .gesture(magnify(in: proxy.size))
                // High priority so a pan inside a zoomed photo beats the page view, which
                // would otherwise read the same drag as "next photo".
                .highPriorityGesture(pan(in: proxy.size), isEnabled: scale > 1)
                .onTapGesture(count: 2) { toggleZoom() }
        }
        .onChange(of: scale) { _, newValue in
            isZoomed = newValue > 1.01
        }
        .onDisappear {
            // A page left zoomed would otherwise keep the whole viewer's drag disabled
            // after it has scrolled away.
            reset(animated: false)
        }
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 0.7), Self.maxScale)
            }
            .onEnded { _ in
                if scale < 1.05 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { reset(animated: true) }
                } else {
                    committedScale = scale
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        offset = clamped(offset, in: size)
                    }
                    committedOffset = clamped(offset, in: size)
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    offset = clamped(offset, in: size)
                }
                committedOffset = clamped(offset, in: size)
            }
    }

    /// Keeps the photo from being dragged off its own frame — past the edge there is
    /// nothing to look at, and letting it go there means every pan ends in a correction.
    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let slackX = max(0, (size.width * scale - size.width) / 2)
        let slackY = max(0, (size.height * scale - size.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if scale > 1.01 {
                reset(animated: true)
            } else {
                scale = Self.doubleTapScale
                committedScale = Self.doubleTapScale
            }
        }
    }

    private func reset(animated: Bool) {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
        isZoomed = false
    }
}
