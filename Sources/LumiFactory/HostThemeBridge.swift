import Combine
import LumiThemePack
import LumiUI
import ProviderTheme
import SwiftUI

/// 把 `ThemeProviding` 的选中主题桥接到 LumiUI 主题体系。
///
/// 三份旧 Factory 各自复制过这段桥接（Wakey ThemeSynchronizer / Cisum
/// ThemeBridge / Lumi FactoryLumi），语义完全一致，统一收敛到这里：
/// `ResolvedSystemColorScheme` → `ActiveChromeTheme` → `LumiUIThemeStore`
/// → macOS 窗口外观同步。
@MainActor
public enum HostThemeSynchronizer {
    public static func sync(_ provider: any ProviderTheme.ThemeProviding) {
        guard let selected = provider.selectedTheme else { return }

        let colorScheme: ColorScheme
        switch selected.appearanceKind {
        case .dark:
            colorScheme = .dark
        case .light:
            colorScheme = .light
        case .system:
            colorScheme = SystemAppearanceResolver.effectiveColorScheme
        }

        ResolvedSystemColorScheme.current = colorScheme
        let chrome = LumiPaletteChromeTheme(theme: selected, colorScheme: colorScheme)
        ActiveChromeTheme.current = chrome
        LumiUIThemeStore.shared.setTheme(ChromeToUIThemeAdapter(chrome: chrome))
        #if os(macOS)
        ThemeWindowAppearanceSync.syncAllWindows()
        #endif
    }
}

/// 主题宿主视图：内容随主题切换重新桥接，并同步明暗外观与背景色。
///
/// macOS 侧额外监听系统外观变化（`AppleInterfaceThemeChangedNotification`），
/// 「跟随系统」的主题在系统切明暗时立即跟上。
@MainActor
public struct HostThemeView<Content: View>: View {
    private let theme: any ProviderTheme.ThemeProviding
    private let content: Content

    @StateObject private var observation: ThemeObservation
    @State private var refreshTick = false

    public init(theme: any ProviderTheme.ThemeProviding, content: Content) {
        self.theme = theme
        self.content = content
        _observation = StateObject(wrappedValue: ThemeObservation(theme: theme))
    }

    public var body: some View {
        let _ = refreshTick

        content
            .preferredColorScheme(preferredColorScheme)
            .background(backgroundColor)
            .onAppear { HostThemeSynchronizer.sync(theme) }
            .onReceive(observation.$revision) { _ in
                refreshTick.toggle()
                HostThemeSynchronizer.sync(theme)
            }
        #if os(macOS)
            .onReceive(
                DistributedNotificationCenter.default().publisher(
                    for: Notification.Name("AppleInterfaceThemeChangedNotification")
                )
                .receive(on: RunLoop.main)
            ) { _ in
                guard theme.followsSystemAppearance else { return }
                refreshTick.toggle()
                HostThemeSynchronizer.sync(theme)
            }
        #endif
    }

    private var preferredColorScheme: ColorScheme? {
        switch theme.selectedTheme?.appearanceKind ?? .system {
        case .dark: .dark
        case .light: .light
        case .system: ResolvedSystemColorScheme.current
        }
    }

    private var backgroundColor: Color {
        guard let selected = theme.selectedTheme else {
            #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return Color(uiColor: .systemBackground)
            #endif
        }
        let colorScheme = preferredColorScheme ?? SystemAppearanceResolver.effectiveColorScheme
        return selected.palette.backgroundMedium.color(colorScheme: colorScheme)
    }
}

@MainActor
private final class ThemeObservation: ObservableObject {
    @Published private(set) var revision = 0
    private var handle: (any ProviderTheme.ThemeProvidingObserverHandle)?

    init(theme: any ProviderTheme.ThemeProviding) {
        handle = theme.addObserver { [weak self] _ in
            self?.revision += 1
        }
    }
}