import SwiftUI

enum TimelinerDesign {
    static let accent = Color(red: 0.00, green: 0.44, blue: 0.93)
    static let darkAccent = Color(red: 0.59, green: 0.74, blue: 0.98)
    static let success = Color(red: 0.09, green: 0.79, blue: 0.39)

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(red: 0.10, green: 0.10, blue: 0.10)
    }

    static func muted(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.66)
    }

    static func subtle(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.52) : Color.black.opacity(0.42)
    }

    static func line(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)
    }

}

enum SkyPhase: String, CaseIterable, Equatable {
    case midnight
    case dawn
    case morning
    case noon
    case afternoon
    case evening
    case sunset
    case night

    /// The hour this phase is most itself at.
    ///
    /// Phases used to be ranges, and the sky snapped from one to the next at their
    /// borders. They are anchors now: the sky is whatever lies between the two nearest
    /// ones, so a minute's change of time is a minute's change of colour.
    var anchorHour: Double {
        switch self {
        case .midnight: return 2
        case .dawn: return 5.5
        case .morning: return 9
        case .noon: return 12.5
        case .afternoon: return 15.5
        case .evening: return 18
        case .sunset: return 20
        case .night: return 22.5
        }
    }

    static func phase(at date: Date, calendar: Calendar = DateHelpers.calendar) -> Self {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60

        switch hour {
        case ..<4: return .midnight
        case ..<7: return .dawn
        case ..<11: return .morning
        case ..<14: return .noon
        case ..<17: return .afternoon
        case ..<19: return .evening
        case ..<21: return .sunset
        default: return .night
        }
    }

    // The dark-scheme palette variants that used to live here are gone. They existed for
    // a bright sky under forced dark chrome, which the unified background mode no longer
    // allows: `하늘` decides the chrome from the sky itself, so the two can't disagree.
    fileprivate var palette: SkyPalette {
        switch self {
        case .morning:
            return SkyPalette(colors: [0x6FA8DF, 0xA6C9EC, 0xD8E8F7, 0xF3F8FD], sun: 1, moon: 0, stars: 0, clouds: 0.85, haze: 0)
        case .noon:
            return SkyPalette(colors: [0x4E93DB, 0x8FBFEA, 0xCFE5F8, 0xF0F7FE], sun: 1, moon: 0, stars: 0, clouds: 0.65, haze: 0)
        case .afternoon:
            return SkyPalette(colors: [0x5893CE, 0x9FC2E4, 0xDCE6EE, 0xF6F1E7], sun: 1, moon: 0, stars: 0, clouds: 0.75, haze: 0)
        case .evening:
            return SkyPalette(colors: [0x6D82B8, 0xB295BC, 0xEBBE8C, 0xF6E3C6], sun: 1, moon: 0, stars: 0, clouds: 0.50, haze: 0.28)
        case .sunset:
            return SkyPalette(colors: [0x565C93, 0x96659B, 0xD97F5F, 0xF0AF77, 0xF5C998], sun: 1, moon: 0, stars: 0.20, clouds: 0.35, haze: 0.32)
        case .dawn:
            return SkyPalette(colors: [0x262A45, 0x3C3A5C, 0x7A5C6B, 0xC08A74], sun: 0, moon: 0.85, stars: 0.40, clouds: 0.10, haze: 0.24)
        case .night:
            return SkyPalette(colors: [0x0D1224, 0x161E3A, 0x232C4E, 0x2C3556], sun: 0, moon: 1, stars: 0.65, clouds: 0.08, haze: 0)
        case .midnight:
            return SkyPalette(colors: [0x05070F, 0x0B1022, 0x131A36, 0x1A2240], sun: 0, moon: 1, stars: 0.80, clouds: 0.06, haze: 0)
        }
    }
}

/// A colour held in linear light so two of them can be mixed.
///
/// Mixing the sRGB numbers directly is what makes a blue-to-orange crossfade pass through
/// mud: those numbers are gamma-encoded, and averaging them is not averaging any light.
private struct SkyRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(hex: UInt) {
        red = Self.linear(Double((hex >> 16) & 0xFF) / 255)
        green = Self.linear(Double((hex >> 8) & 0xFF) / 255)
        blue = Self.linear(Double(hex & 0xFF) / 255)
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color {
        Color(.sRGBLinear, red: red, green: green, blue: blue)
    }

    /// Relative luminance, the CIE weighting of linear light.
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func mix(_ a: SkyRGB, _ b: SkyRGB, _ t: Double) -> SkyRGB {
        SkyRGB(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t
        )
    }

    private static func linear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
}

private struct SkyPalette: Equatable {
    /// The written palettes have three to five stops each. Two palettes can only be
    /// mixed stop by stop, so every one is resampled onto this many first.
    static let stopCount = 5

    let stops: [SkyRGB]
    let sun: Double
    let moon: Double
    let stars: Double
    let clouds: Double
    let haze: Double

    init(colors: [UInt], sun: Double, moon: Double, stars: Double, clouds: Double, haze: Double) {
        stops = Self.resampled(colors.map(SkyRGB.init(hex:)))
        self.sun = sun
        self.moon = moon
        self.stars = stars
        self.clouds = clouds
        self.haze = haze
    }

    private init(stops: [SkyRGB], sun: Double, moon: Double, stars: Double, clouds: Double, haze: Double) {
        self.stops = stops
        self.sun = sun
        self.moon = moon
        self.stars = stars
        self.clouds = clouds
        self.haze = haze
    }

    var colors: [Color] { stops.map(\.color) }

    /// How light the sky reads overall, back in perceptual terms. Averaging in linear
    /// light and encoding once at the end; averaging the encoded values would weight the
    /// bright stops far too heavily.
    var lightness: Double {
        let mean = stops.reduce(0) { $0 + $1.luminance } / Double(stops.count)
        return mean <= 0.0031308 ? mean * 12.92 : 1.055 * pow(mean, 1 / 2.4) - 0.055
    }

    static func mix(_ a: SkyPalette, _ b: SkyPalette, _ t: Double) -> SkyPalette {
        SkyPalette(
            stops: zip(a.stops, b.stops).map { SkyRGB.mix($0, $1, t) },
            sun: a.sun + (b.sun - a.sun) * t,
            moon: a.moon + (b.moon - a.moon) * t,
            stars: a.stars + (b.stars - a.stars) * t,
            clouds: a.clouds + (b.clouds - a.clouds) * t,
            haze: a.haze + (b.haze - a.haze) * t
        )
    }

    /// Samples the written gradient at evenly spaced positions, so a three-stop palette
    /// and a five-stop one describe the same shape and can be mixed.
    private static func resampled(_ colors: [SkyRGB]) -> [SkyRGB] {
        guard colors.count > 1 else {
            return Array(repeating: colors.first ?? SkyRGB(hex: 0), count: stopCount)
        }
        return (0..<stopCount).map { index in
            let position = Double(index) / Double(stopCount - 1) * Double(colors.count - 1)
            let lower = min(Int(position), colors.count - 2)
            return SkyRGB.mix(colors[lower], colors[lower + 1], position - Double(lower))
        }
    }
}

/// The sky as a continuous function of the clock.
enum Sky {
    private static let anchors: [(hour: Double, palette: SkyPalette)] = SkyPhase.allCases
        .map { (hour: $0.anchorHour, palette: $0.palette) }
        .sorted { $0.hour < $1.hour }

    /// The lightest and darkest the sky ever gets, measured rather than assumed, so the
    /// chrome threshold below stays right if the palettes are ever retuned.
    private static let lightnessRange: (min: Double, max: Double) = {
        let values = anchors.map(\.palette.lightness)
        return (values.min() ?? 0, values.max() ?? 1)
    }()

    fileprivate static func palette(at date: Date) -> SkyPalette {
        let components = DateHelpers.calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
        return palette(atHour: hour)
    }

    fileprivate static func palette(atHour hour: Double) -> SkyPalette {
        let hour = hour.truncatingRemainder(dividingBy: 24)

        for index in anchors.indices {
            let start = anchors[index].hour
            // The last segment runs off the end of the day and back onto the first
            // anchor, which is why the whole thing is a circle and not a list.
            let isLast = index == anchors.count - 1
            let end = isLast ? anchors[0].hour + 24 : anchors[index + 1].hour
            let position = hour >= start ? hour : hour + 24

            guard position >= start, position < end else { continue }

            let raw = (position - start) / (end - start)
            // Eased, so the sky arrives at and leaves each anchor without a corner.
            let t = raw * raw * (3 - 2 * raw)
            return SkyPalette.mix(
                anchors[index].palette,
                anchors[isLast ? 0 : index + 1].palette,
                t
            )
        }

        return anchors[0].palette
    }

    /// Where the sky crosses its own midpoint, rather than at a phase boundary.
    ///
    /// The chrome cannot fade the way the sky now does — light and dark is a switch. What
    /// it can do is throw at the least conspicuous moment, which is where the sky is
    /// halfway between its darkest and its brightest.
    static func prefersDarkChrome(at date: Date) -> Bool {
        let threshold = (lightnessRange.min + lightnessRange.max) / 2
        return palette(at: date).lightness < threshold
    }
}

private struct SkyStar: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
}

struct TimeOfDayBackground: View {
    let date: Date

    var body: some View {
        // No `.id(phase)` and no crossfade any more. Both existed to paper over the jump
        // between one phase's palette and the next; there is no jump left to cover, and
        // dragging the clock across a boundary used to restart that fade over and over,
        // which is what made the sky stutter rather than move.
        SkyScene(date: date, palette: Sky.palette(at: date))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct SkyScene: View {
    let date: Date
    let palette: SkyPalette

    private static let stars = [
        SkyStar(id: 0, x: 0.12, y: 0.08, size: 2.2),
        SkyStar(id: 1, x: 0.28, y: 0.05, size: 2.6),
        SkyStar(id: 2, x: 0.44, y: 0.11, size: 1.8),
        SkyStar(id: 3, x: 0.62, y: 0.06, size: 2.4),
        SkyStar(id: 4, x: 0.78, y: 0.10, size: 2.0),
        SkyStar(id: 5, x: 0.89, y: 0.04, size: 2.6),
        SkyStar(id: 6, x: 0.20, y: 0.16, size: 2.0),
        SkyStar(id: 7, x: 0.55, y: 0.18, size: 2.2),
        SkyStar(id: 8, x: 0.70, y: 0.21, size: 1.8),
        SkyStar(id: 9, x: 0.36, y: 0.23, size: 2.4)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: palette.colors,
                    startPoint: .top,
                    endPoint: .bottom
                )

                stars(in: proxy.size)
                haze

                if palette.sun > 0 {
                    sun(in: proxy.size)
                }
                if palette.moon > 0 {
                    moon(in: proxy.size)
                }

                clouds(in: proxy.size)
            }
        }
    }

    private func stars(in size: CGSize) -> some View {
        ZStack {
            ForEach(Self.stars) { star in
                Circle()
                    .fill(Color.white.opacity(palette.stars))
                    .frame(width: star.size, height: star.size)
                    .position(x: size.width * star.x, y: size.height * star.y)
            }
        }
    }

    private var haze: some View {
        LinearGradient(
            colors: [.clear, Color(red: 1.0, green: 0.63, blue: 0.40).opacity(palette.haze)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
        .containerRelativeFrame(.vertical) { height, _ in height * 0.46 }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func sun(in size: CGSize) -> some View {
        let position = celestialPosition(for: .sun, in: size)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.74).opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 260))
                .frame(width: 520, height: 520)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.84).opacity(0.74), Color(red: 1.0, green: 0.86, blue: 0.60).opacity(0.20), .clear], center: .center, startRadius: 0, endRadius: 130))
                .frame(width: 260, height: 260)
                .blur(radius: 6)
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.95), Color(red: 1.0, green: 0.86, blue: 0.55), .clear], center: .center, startRadius: 0, endRadius: 60))
                .frame(width: 120, height: 120)
                .blur(radius: 7)
        }
        .opacity(palette.sun)
        .position(position)
    }

    private func moon(in size: CGSize) -> some View {
        let position = celestialPosition(for: .moon, in: size)
        let diameter: CGFloat = 54
        return ZStack {
            // The glow has to stay dimmer than the disc it comes off, or the moon reads
            // as a hole in a cloud rather than the source of the light. It also has to
            // share the disc's colour: a blue-white halo around a warm grey moon is the
            // pairing that looks like two objects sitting on top of each other.
            //
            // So: narrow, faint, and warm — and the corona starts at the limb rather
            // than the centre, so nothing is ever laid over the photograph.
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.93, green: 0.92, blue: 0.88).opacity(0.09), .clear], center: .center, startRadius: 0, endRadius: 84))
                .frame(width: 168, height: 168)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.99, green: 0.96, blue: 0.89).opacity(0.20), .clear],
                        center: .center,
                        startRadius: diameter * 0.48,
                        endRadius: diameter * 0.98
                    )
                )
                .frame(width: diameter * 2, height: diameter * 2)
                .blur(radius: 5)

            MoonDisc(diameter: diameter)
        }
        .opacity(palette.moon)
        .position(position)
    }

    private func clouds(in size: CGSize) -> some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color.white.opacity(0.90), Color.white.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 86)
                .blur(radius: 18)
                .position(x: 70, y: min(150, size.height * 0.18))
            Ellipse()
                .fill(RadialGradient(colors: [Color.white.opacity(0.78), Color.white.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 170))
                .frame(width: 340, height: 96)
                .blur(radius: 22)
                .position(x: size.width - 40, y: min(350, size.height * 0.42))
        }
        .opacity(palette.clouds)
    }

    private enum CelestialBody { case sun, moon }

    private func celestialPosition(for body: CelestialBody, in size: CGSize) -> CGPoint {
        let components = DateHelpers.calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
        let progress: Double

        switch body {
        case .sun:
            progress = min(max((hour - 5.5) / 13, 0), 1)
        case .moon:
            let normalizedHour = hour < 10 ? hour + 24 : hour
            progress = min(max((normalizedHour - 21) / 8.5, 0), 1)
        }

        let x = 0.06 + 0.84 * (progress * (2 - progress))
        let y = 0.17 + 0.57 * progress * progress
        return CGPoint(x: size.width * x, y: size.height * y)
    }
}

/// The moon, built on a real photograph of it.
///
/// `MoonSurface` is NASA SVS's Moon Mosaic — 1,231 frames from the Lunar Reconnaissance
/// Orbiter's narrow angle camera, stitched into one near-side disc. Credit: NASA's
/// Scientific Visualization Studio. It ships at 512px against 54pt on screen, which is
/// what keeps the mosaic's tile seams from surfacing; they are plainly visible at full
/// resolution and gone by the time it is drawn.
///
/// The photograph is orthographic and evenly lit, so on its own it reads as a flat
/// medallion. Everything layered over it is there to put it back in the sky: limb
/// darkening to curve it away at the rim, a warm cast to lift it off the blue, a soft
/// mask so it dissolves into its own glow instead of ending on a cut edge.
private struct MoonDisc: View {
    let diameter: CGFloat

    var body: some View {
        Image("MoonSurface")
            .resizable()
            .interpolation(.high)
            // The disc sits a couple of percent inside its frame, so it is pushed out to
            // meet the mask — otherwise a ring of the photograph's black sky survives
            // around the limb and reads as a dark outline.
            .scaleEffect(1.05)
            .frame(width: diameter, height: diameter)
            // Shot against black and printed dark; the sky here is darker still, and a
            // moon that does not out-glow its own halo looks like a hole in it. Pushed
            // until the highlands sit near white and the maria carry the contrast.
            .brightness(0.13)
            .contrast(1.18)
            .saturation(0)
            .overlay { warmth }
            .overlay { limbDarkening }
            .overlay { rimLight }
            .mask { edge }
    }

    /// Regolith photographs neutral grey, which against this blue sky turns faintly cold
    /// and synthetic. A touch of sunlight colour, screened over the highlights only.
    private var warmth: some View {
        Color(red: 1.0, green: 0.94, blue: 0.82)
            .blendMode(.softLight)
            .opacity(0.55)
    }

    /// Held clear across the middle so only the outer third rolls off. Starting the
    /// falloff any earlier flattens the disc back into a vignette.
    private var limbDarkening: some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.62),
                        .init(color: Color(red: 0.14, green: 0.16, blue: 0.26).opacity(0.52), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
    }

    /// A hairline catch along the sunward edge, which is what sells the rim as an edge
    /// rather than where the picture stops.
    private var rimLight: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.55), .clear, .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: max(0.6, diameter * 0.016)
            )
    }

    /// Opaque almost to the rim, then a sub-pixel-scale falloff. A plain `clipShape`
    /// leaves an aliased edge that catches the eye against a dark sky and gives the
    /// cut-out away; fading the last two percent hands the disc over to the glow.
    private var edge: some View {
        RadialGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1)
            ],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.5
        )
    }
}

/// Liquid Glass design philosophy:
///   - Let the system manage chrome (TabView, NavigationStack, toolbars)
///     and let `.glassEffect()` / materials carry the depth.
///   - Content surfaces stay calm; saturate only where the user looks
///     (status pills, action buttons, accent).
///   - All colors below are content-only; chrome inherits from the system.
struct PillColorPair {
    let tint: Color           // primary tint (icon background, accent)
    let foreground: Color     // text + icon foreground
    let surface: Color        // soft background tint for container
}

enum PillColors {
    static func colors(for theme: ScheduleColorTheme, dark: Bool) -> PillColorPair {
        switch theme {
        case .emerald:
            return PillColorPair(
                tint: Color(red: 0.03, green: 0.59, blue: 0.41),
                foreground: dark ? Color(red: 0.70, green: 0.95, blue: 0.85)
                                 : Color(red: 0.02, green: 0.37, blue: 0.27),
                surface: dark ? Color.green.opacity(0.18) : Color.green.opacity(0.10))
        case .orange:
            return PillColorPair(
                tint: Color(red: 0.85, green: 0.46, blue: 0.02),
                foreground: dark ? Color(red: 1.00, green: 0.87, blue: 0.70)
                                 : Color(red: 0.55, green: 0.25, blue: 0.05),
                surface: dark ? Color.orange.opacity(0.20) : Color.orange.opacity(0.12))
        case .blue:
            return PillColorPair(
                tint: Color(red: 0.05, green: 0.45, blue: 0.95),
                foreground: dark ? Color(red: 0.75, green: 0.87, blue: 1.00)
                                 : Color(red: 0.08, green: 0.27, blue: 0.65),
                surface: dark ? Color.blue.opacity(0.22) : Color.blue.opacity(0.10))
        case .purple:
            return PillColorPair(
                tint: Color(red: 0.49, green: 0.23, blue: 0.93),
                foreground: dark ? Color(red: 0.90, green: 0.85, blue: 1.00)
                                 : Color(red: 0.32, green: 0.13, blue: 0.65),
                surface: dark ? Color.purple.opacity(0.22) : Color.purple.opacity(0.10))
        case .gray:
            return PillColorPair(
                tint: Color.gray,
                foreground: dark ? Color(white: 0.90) : Color(white: 0.30),
                surface: dark ? Color.gray.opacity(0.30) : Color.gray.opacity(0.15))
        }
    }
}

enum TimelinerFont {
    static func main(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Glass card helper

extension View {
    /// A subtle glass surface for content cards. Picks between a real
    /// `glassEffect` (iOS 26+) and a material fallback otherwise.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(0.07), radius: 12, y: 4)
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
    }
}

// MARK: - Backgrounds

/// An Unsplash photo, reachable without an API key.
///
/// Unsplash's own API needs a key and their site refuses scrapers, so the images come
/// through Lorem Picsum, which serves Unsplash photography and reports the photographer
/// and the original page for each one. Every entry below was fetched and checked before
/// it was written down; the credit and link are the attribution Unsplash asks for.
struct UnsplashBackground: Identifiable, Hashable {
    let id: String
    let author: String
    let sourceURL: URL

    func imageURL(width: Int, height: Int) -> URL {
        URL(string: "https://picsum.photos/id/\(id)/\(width)/\(height)")!
    }

    static let all: [UnsplashBackground] = [
        Self("1002", "NASA", "6-jTZysYY_U"),
        Self("903", "Greg Rakozy", "oMpAz-DN-9I"),
        Self("870", "Joshua Hibbert", "Pn6iimgM-wo"),
        Self("1015", "Alexey Topolyanskiy", "-oWyJoSqBRM"),
        Self("1018", "Andrew Ridley", "Kt5hRENuotI"),
        Self("1036", "Wolfgang Lutz", "yOujaSETXlo"),
        Self("1043", "Christian Joudrey", "mWRR1xj95hg"),
        Self("1044", "Steve Carter", "Ixp4YhCKZkI"),
        Self("1051", "Ales Krivec", "HkTMcmlMOUQ"),
        Self("1016", "Philippe Wuyts", "_h7aBovKia4")
    ]

    private init(_ id: String, _ author: String, _ slug: String) {
        self.id = id
        self.author = author
        self.sourceURL = URL(string: "https://unsplash.com/photos/\(slug)")!
    }

    static func named(_ id: String) -> UnsplashBackground {
        all.first { $0.id == id } ?? all[0]
    }
}

private struct BackgroundDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    /// The moment the background draws, resolved once at the root and handed down.
    var backgroundDate: Date {
        get { self[BackgroundDateKey.self] }
        set { self[BackgroundDateKey.self] = newValue }
    }
}

/// Whatever the appearance setting says should be behind the app.
///
/// Every screen draws it rather than relying on one copy at the root: a `NavigationStack`
/// brings its own opaque background, so a screen that paints nothing gets the system's
/// grey instead of what is behind it. One view and one clock, applied in several places —
/// which is not the same thing as several implementations.
struct AppBackground: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundDate) private var date

    var body: some View {
        Group {
            switch appearance.mode {
            case .sky:
                TimeOfDayBackground(date: date)
            case .light:
                flat(dark: false)
            case .dark:
                flat(dark: true)
            case .system:
                flat(dark: scheme == .dark)
            case .custom:
                custom
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// A gradient rather than a dead flat fill. The cards on top are glass; given nothing
    /// to refract they stop reading as glass at all.
    private func flat(dark: Bool) -> some View {
        LinearGradient(
            colors: dark
                ? [Color(white: 0.09), Color(white: 0.13), Color(white: 0.08)]
                : [Color(white: 0.97), Color(white: 0.93), Color(white: 0.96)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var custom: some View {
        ZStack {
            // Under the photo, so a slow-loading or missing image leaves something
            // deliberate rather than a white flash.
            flat(dark: scheme == .dark)

            switch appearance.customSource {
            case .photo:
                CustomPhotoBackground(version: appearance.customPhotoVersion)
            case .unsplash:
                UnsplashImage(
                    background: .named(appearance.unsplashBackgroundID),
                    width: 1_170,
                    height: 2_532
                )
            }

            // The photo is somebody else's; the text on top is the app's. The scrim is
            // what keeps the second legible over any version of the first.
            Rectangle()
                .fill(scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.34))
        }
    }
}

/// The photo picked from the library, read back off disk.
private struct CustomPhotoBackground: View {
    let version: Int

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            // Keyed on the version rather than the path, which never changes even when
            // the photo behind it does.
            .task(id: version) {
                image = await Self.load()
            }
    }

    private static func load() async -> UIImage? {
        let url = AppearanceSettings.customPhotoURL
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}

/// One curated Unsplash photo. Served from `URLCache`, which the app sizes at launch, so
/// a background picked once keeps working without the network.
struct UnsplashImage: View {
    let background: UnsplashBackground
    let width: Int
    let height: Int

    var body: some View {
        AsyncImage(url: background.imageURL(width: width, height: height)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Color.clear
            }
        }
        .clipped()
    }
}

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
