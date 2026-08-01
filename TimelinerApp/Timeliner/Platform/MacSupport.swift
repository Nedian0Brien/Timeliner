import SwiftUI
import UIKit

/// 맥(Mac Catalyst)에서만 달라지는 것들.
///
/// 같은 타깃 하나가 아이폰과 맥을 동시에 만든다. 그래서 이 파일의 모든 분기는
/// `#if targetEnvironment(macCatalyst)` 뒤에 있고, iOS 빌드에서는 남김없이 통과
/// 코드가 된다. 화면 파일마다 `#if`를 흩뿌리는 대신 여기 모아 두면, 아이폰 화면을
/// 고칠 때 맥을 신경 쓸 일이 없다.

enum MacLayout {
    /// 본문 한 단의 최대 폭.
    ///
    /// 폰 폭(393)의 1.7배쯤. 창을 늘렸을 때 기록 한 줄이 화면을 가로지르는 리본이
    /// 되지 않는 한계에서 끊었다.
    static let readableWidth: CGFloat = 680

    /// 이보다 좁아지면 타임라인 왼쪽 레일과 본문이 겹치기 시작한다.
    static let minimumWindowSize = CGSize(width: 520, height: 620)
}

// MARK: - 읽을 만한 한 단

/// 화면 한 장의 본문만 읽을 만한 폭으로 모은다.
///
/// 프레임을 잘라서 좁히지 않고 안전 영역을 양옆에서 밀어 넣는다. 프레임을 자르면
/// 화면이 통째로 좁아져서 하늘도 내비게이션 바도 같이 줄고, 그 바깥은 `TabView`의
/// 불투명한 기본 배경이 드러난다. 안전 영역만 밀면 배경과 크롬은 창을 그대로 덮은
/// 채 카드와 큰 제목만 가운데로 모인다.
private struct MacColumn: ViewModifier {
    let width: CGFloat

    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .safeAreaPadding(.horizontal, inset)
            // 여백은 안전 영역만 건드리므로 재는 폭이 이 때문에 달라지지 않는다.
            // 되먹임 없이 창 폭을 그대로 읽는다.
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(0, (proxy.size.width - width) / 2)
            } action: { inset = $0 }
        #else
        content
        #endif
    }
}

/// 폭만 묶는다. 아래에 붙는 입력 알약처럼 제 높이와 제 배경을 그대로 둬야 하는 것들용.
private struct MacColumnWidth: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
        #else
        content
        #endif
    }
}

extension View {
    /// 맥에서만 화면 폭을 묶고 가운데 세운다. iOS·iPadOS에서는 아무 일도 하지 않는다.
    func macColumn(_ width: CGFloat = MacLayout.readableWidth) -> some View {
        modifier(MacColumn(width: width))
    }

    /// 맥에서만 가로 폭을 묶는다. 배경과 높이는 건드리지 않는다.
    func macColumnWidth(_ width: CGFloat = MacLayout.readableWidth) -> some View {
        modifier(MacColumnWidth(width: width))
    }

    /// 맥에서만 큰 제목을 인라인으로 내린다.
    ///
    /// 큰 제목은 내비게이션 바가 그리는 것이라 `macColumn`의 여백을 따라오지 않는다.
    /// 본문이 가운데로 모인 창에서 제목만 왼쪽 끝에 남는다. 맥에서는 창 위 탭 막대가
    /// 이미 화면 이름을 말하고 있으니, 크게 둘 이유도 없다.
    func macInlineTitle() -> some View {
        #if targetEnvironment(macCatalyst)
        self.toolbarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - 창

#if targetEnvironment(macCatalyst)
@MainActor
enum MacWindow {
    /// 창이 더 좁아지지 못하게 막는다. 이보다 좁은 창은 여기서 바로 넓혀지기도 해서,
    /// 첫 실행에 쓸 만한 크기를 따로 계산해 넣을 필요가 없다.
    ///
    /// `maximumSize`는 건드리지 않는다. 기본값이 이미 무제한이고, 무한대에 가까운 수를
    /// 넣으면 제한 객체가 통째로 무시되어 `minimumSize`까지 함께 죽는다.
    static func configure() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = MacLayout.minimumWindowSize
        }
    }
}
#endif

/// 창 크기 제한을 거는 자리.
///
/// `onAppear` 한 번으로는 부족하다. 뷰가 처음 나타나는 시점에 씬이 아직
/// `connectedScenes`에 없을 수 있어서, 씬이 활성화될 때 한 번 더 건다. 두 번 걸어도
/// 결과는 같다.
private struct MacWindowSetup: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .onAppear { MacWindow.configure() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                MacWindow.configure()
            }
        #else
        content
        #endif
    }
}

extension View {
    /// 창이 뜨는 순간 크기 제한을 건다. iOS에서는 아무 일도 하지 않는다.
    func macWindowSetup() -> some View {
        modifier(MacWindowSetup())
    }
}

// MARK: - 권한 설정 열기

/// 권한을 거절한 뒤에 다시 켜러 가는 곳. 아이폰은 앱 설정 화면, 맥은 시스템 설정의
/// 해당 패널이라 문구도 주소도 다르다.
enum PrivacySettings {
    enum Pane {
        case notifications
        case reminders
        case calendars
    }

    /// 버튼과 안내 문구에 쓸 이름. 맥에서 "iOS 설정"이라고 적혀 있으면 갈 곳이 없다.
    static var appName: String {
        #if targetEnvironment(macCatalyst)
        "시스템 설정"
        #else
        "iOS 설정"
        #endif
    }

    @MainActor
    static func open(_ pane: Pane) {
        guard let url = url(for: pane) else { return }
        UIApplication.shared.open(url)
    }

    private static func url(for pane: Pane) -> URL? {
        #if targetEnvironment(macCatalyst)
        // 맥에는 앱별 설정 화면이 없다. 시스템 설정에서 해당 항목을 바로 연다.
        switch pane {
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        case .reminders:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        case .calendars:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        }
        #else
        return URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

// MARK: - 메뉴 막대

/// 메뉴에서 화면을 바꾸려면 그 상태를 쥔 뷰가 자기를 알려 줘야 한다. 창이 하나뿐인
/// 앱이라 씬 단위 포커스 값이면 충분하다.
private struct SelectedTabKey: FocusedValueKey {
    typealias Value = Binding<AppTab>
}

extension FocusedValues {
    var selectedTab: Binding<AppTab>? {
        get { self[SelectedTabKey.self] }
        set { self[SelectedTabKey.self] = newValue }
    }
}

#if targetEnvironment(macCatalyst)
/// 맥 메뉴 막대에 얹는 것.
///
/// 딱 하나다. Catalyst의 메뉴 막대는 시스템이 이미 만들어 둔 자리를
/// `CommandGroup(replacing:)`으로 **바꾸는** 것만 받아들이고, `CommandMenu`로 새 메뉴를
/// 내거나 `CommandGroup(after:)`로 항목을 **더하는** 것은 화면에 나타나지 않았다.
/// 새 기록(⌘N)을 여기 얹으려던 시도가 그래서 죽었고, 지금은 화면 아래 알약으로만 연다.
///
/// 탭 전환은 코드가 필요 없다. Catalyst가 탭 막대에 ⌘1–⌘4를 알아서 붙여 준다.
struct TimelinerCommands: Commands {
    @FocusedBinding(\.selectedTab) private var selectedTab

    var body: some Commands {
        // 맥에서 ⌘,는 설정이다. 여기서는 설정 탭으로 간다.
        CommandGroup(replacing: .appSettings) {
            Button("설정…") { selectedTab = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
