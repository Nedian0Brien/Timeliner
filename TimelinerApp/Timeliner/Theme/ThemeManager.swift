import Combine
import SwiftUI
import UIKit

/// What sits behind everything, and — because the two cannot sensibly disagree — how
/// bright the chrome on top of it is.
///
/// This replaces the old light/dark/system preference rather than sitting beside it.
/// Two controls over the same axis meant "라이트 배경 + 다크 화면" was expressible, and
/// nothing good was on the other side of that combination.
enum BackgroundMode: String, CaseIterable, Identifiable {
    case sky, light, dark, system, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sky: return "하늘"
        case .light: return "라이트"
        case .dark: return "다크"
        case .system: return "시스템"
        case .custom: return "커스텀"
        }
    }

    var systemImage: String {
        switch self {
        case .sky: return "sun.horizon"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        case .custom: return "photo"
        }
    }

    var detail: String {
        switch self {
        case .sky: return "시간대를 따라 하늘과 밝기가 함께 바뀝니다."
        case .light: return "밝은 배경에 고정합니다."
        case .dark: return "어두운 배경에 고정합니다."
        case .system: return "기기의 라이트/다크 설정을 따릅니다."
        case .custom: return "고른 사진을 배경으로 씁니다. 글자가 읽히도록 위에 얇은 막을 덮습니다."
        }
    }
}

enum CustomBackgroundSource: String, CaseIterable, Identifiable {
    case photo, unsplash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "내 사진"
        case .unsplash: return "Unsplash"
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    @AppStorage("backgroundMode") private var rawMode: String = BackgroundMode.sky.rawValue {
        didSet { objectWillChange.send() }
    }

    /// Minutes past midnight the background should pretend it is, or `liveClock` for the
    /// real one.
    ///
    /// Background only, deliberately. It moves the sky and the chrome that reads off the
    /// sky; it does not move the timeline's "지금", which stays anchored to the actual
    /// clock so nothing about what is past or upcoming is ever a lie.
    @AppStorage("backgroundPreviewMinutes") private var storedPreviewMinutes: Int = liveClock {
        didSet { objectWillChange.send() }
    }

    @AppStorage("customBackgroundSource") private var rawCustomSource: String = CustomBackgroundSource.unsplash.rawValue {
        didSet { objectWillChange.send() }
    }

    @AppStorage("unsplashBackgroundID") var unsplashBackgroundID: String = UnsplashBackground.all[0].id {
        didSet { objectWillChange.send() }
    }

    /// Bumped whenever the picked photo is replaced, so views holding the old one are
    /// told to look again — the file path never changes.
    @AppStorage("customPhotoVersion") private(set) var customPhotoVersion: Int = 0 {
        didSet { objectWillChange.send() }
    }

    static let liveClock = -1

    /// Tracked rather than asked of the filesystem on every body evaluation, which is
    /// what a computed `FileManager.fileExists` would amount to.
    @Published private(set) var hasCustomPhoto: Bool

    init() {
        hasCustomPhoto = FileManager.default.fileExists(atPath: Self.customPhotoURL.path)
    }

    var mode: BackgroundMode {
        get { BackgroundMode(rawValue: rawMode) ?? .sky }
        set { rawMode = newValue.rawValue }
    }

    var customSource: CustomBackgroundSource {
        get { CustomBackgroundSource(rawValue: rawCustomSource) ?? .unsplash }
        set { rawCustomSource = newValue.rawValue }
    }

    var previewMinutes: Int {
        get { storedPreviewMinutes }
        set { storedPreviewMinutes = newValue }
    }

    var usesPreviewTime: Bool { storedPreviewMinutes != Self.liveClock }

    func resetPreviewTime() { storedPreviewMinutes = Self.liveClock }

    /// The moment the background should be drawn for.
    func backgroundDate(now: Date) -> Date {
        guard usesPreviewTime else { return now }
        let day = DateHelpers.startOfDay(now)
        return DateHelpers.calendar.date(byAdding: .minute, value: storedPreviewMinutes, to: day) ?? now
    }

    /// `nil` hands the decision to the system.
    func colorScheme(backgroundDate: Date) -> ColorScheme? {
        switch mode {
        case .sky: return Sky.prefersDarkChrome(at: backgroundDate) ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .system, .custom: return nil
        }
    }

    // MARK: - The picked photo

    static let customPhotoURL = URL.applicationSupportDirectory
        .appending(path: "CustomBackground.jpg")

    /// Stored downsampled: a background is drawn at screen size, and holding a 12
    /// megapixel original to draw it would cost memory nothing on screen benefits from.
    func storeCustomPhoto(_ data: Data) {
        guard let image = UIImage(data: data),
              let downsampled = Self.downsampled(image, maxDimension: 1_800),
              let jpeg = downsampled.jpegData(compressionQuality: 0.85)
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: URL.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            try jpeg.write(to: Self.customPhotoURL, options: .atomic)
            customPhotoVersion += 1
            hasCustomPhoto = true
        } catch {
            // Nothing to recover: the previous photo, if any, is still on disk and still
            // what the background will draw.
        }
    }

    private static func downsampled(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
