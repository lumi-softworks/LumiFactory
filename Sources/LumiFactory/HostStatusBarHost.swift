#if os(macOS)
import AppKit
import KernelCore
import LumiUI
import MenuBarHostKit
import OSLog
import ProviderLogo
import ProviderMenuBar
import ProviderTheme
import SwiftUI

/// 共享状态栏控制器：安装菜单栏图标 + 弹窗，监听高亮请求。
///
/// 高亮有两条来源，这里都支持：
/// - 新契约：`LogoProviding.setLogoHighlighted`（Provider 自带观察者）；
/// - 旧契约：`requestStatusBarAppearanceUpdate` 通知（存量插件仍在发，
///   多来源聚合——任一来源激活即高亮）。
@MainActor
public final class HostStatusBarController: NSObject {
    private let logger: Logger
    private let configuration: HostStatusBarConfiguration
    private let identity: HostIdentity
    private let menuBarHost = MenuBarHost()
    private let iconViewModel = HostStatusBarIconViewModel()
    private var activeSources: Set<String> = []
    private weak var kernel: KernelCoreContainer?

    public init(manifest: HostManifest) {
        self.configuration = manifest.features.statusBar ?? HostStatusBarConfiguration()
        self.identity = manifest.identity
        self.logger = Logger(subsystem: manifest.identity.loggerSubsystem, category: "statusbar")
        super.init()
    }

    /// 安装状态栏项（幂等）。内核就绪后调用。
    public func install(kernel: KernelCoreContainer) {
        self.kernel = kernel
        guard !menuBarHost.isInstalled else { return }

        let iconView = configuration.makeIconView?(kernel)
            ?? AnyView(HostStatusBarIconView(viewModel: iconViewModel, kernel: kernel))

        menuBarHost.install(
            statusView: iconView,
            configuration: MenuBarHostConfiguration(
                statusViewHeight: configuration.statusViewHeight,
                popoverSizing: .fixedWidth(
                    configuration.popoverWidth,
                    maximumHeight: configuration.popoverMaximumHeight
                ),
                accessibilityIdentifier: configuration.accessibilityIdentifier
                    ?? "\(identity.accessibilityPrefix).statusbar.button",
                accessibilityLabel: identity.appName,
                activatesApplication: configuration.activatesApplication
            )
        ) { [weak self] in
            self?.makePopupView() ?? AnyView(EmptyView())
        }

        guard menuBarHost.isInstalled else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceUpdate(_:)),
            name: .requestStatusBarAppearanceUpdate,
            object: nil
        )
        logger.info("Status bar installed")
    }

    public func cleanup() {
        menuBarHost.cleanup()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppearanceUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let isActive = userInfo["isActive"] as? Bool,
              let source = userInfo["source"] as? String else { return }

        if isActive {
            activeSources.insert(source)
        } else {
            activeSources.remove(source)
        }
        iconViewModel.isActive = !activeSources.isEmpty
    }

    private func makePopupView() -> AnyView {
        guard let kernel else { return AnyView(EmptyView()) }
        let menuBar = kernel.resolveProvider(MenuBarProviding.self)
        let content = HostStatusBarHostView(
            manifest: HostStatusBarManifestSnapshot(identity: identity, configuration: configuration),
            menuBar: menuBar
        )
        let themed: AnyView
        if let theme = kernel.resolveProvider((any ProviderTheme.ThemeProviding).self) {
            HostThemeSynchronizer.sync(theme)
            themed = AnyView(HostThemeView(theme: theme, content: content))
        } else {
            themed = AnyView(content)
        }
        if let wrapPopup = configuration.wrapPopup {
            return wrapPopup(themed, kernel)
        }
        return themed
    }
}

/// 弹窗所需的清单快照（避免视图持有整份清单）。
private struct HostStatusBarManifestSnapshot {
    let identity: HostIdentity
    let configuration: HostStatusBarConfiguration
}

@MainActor
private final class HostStatusBarIconViewModel: ObservableObject {
    @Published var isActive = false
}

/// 状态栏图标：Logo Provider 的最高优先级项，按高亮态切换场景。
private struct HostStatusBarIconView: View {
    @ObservedObject var viewModel: HostStatusBarIconViewModel
    let kernel: KernelCoreContainer
    @StateObject private var logoObservation: HostLogoObservation

    init(viewModel: HostStatusBarIconViewModel, kernel: KernelCoreContainer) {
        self.viewModel = viewModel
        self.kernel = kernel
        _logoObservation = StateObject(wrappedValue: HostLogoObservation(kernel: kernel))
    }

    private var isHighlighted: Bool {
        viewModel.isActive
            || (kernel.resolveProvider(LogoProviding.self)?.isLogoHighlighted ?? false)
    }

    var body: some View {
        let _ = logoObservation.revision
        HostLogoView(
            kernel: kernel,
            scene: isHighlighted ? .statusBarHighlighted : .statusBar
        )
        .frame(width: 20, height: 20)
    }
}

/// Logo 变更观察者（句柄必须强持有，Provider 只保留弱引用）。
@MainActor
private final class HostLogoObservation: ObservableObject {
    @Published private(set) var revision = 0
    private var handle: (any LogoObserverHandle)?

    init(kernel: KernelCoreContainer) {
        handle = kernel.resolveProvider(LogoProviding.self)?.addLogoObserver { [weak self] _ in
            self?.revision += 1
        }
    }
}

/// Logo 视图：取最高优先级项渲染指定场景；无 Logo 时用中性占位图标。
public struct HostLogoView: View {
    private let kernel: KernelCoreContainer?
    private let scene: LogoScene
    private let selectedLogoId: String?

    public init(kernel: KernelCoreContainer?, scene: LogoScene = .general, selectedLogoId: String? = nil) {
        self.kernel = kernel
        self.scene = scene
        self.selectedLogoId = selectedLogoId
    }

    public var body: some View {
        if let logo = resolveLogo() {
            logo.makeView(scene)
        } else {
            fallback
        }
    }

    private func resolveLogo() -> LogoItem? {
        let logos = kernel?.resolveProvider(LogoProviding.self)?.allLogoItems ?? []
        return selectedLogoId.flatMap { id in logos.first { $0.id == id } } ?? logos.first
    }

    @ViewBuilder
    private var fallback: some View {
        switch scene {
        case .statusBar:
            Image(systemName: "app.dashed")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
        case .statusBarHighlighted:
            Image(systemName: "app.dashed")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
        default:
            Image(systemName: "app.dashed")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
        }
    }
}

/// 状态栏弹窗：应用信息 + 插件贡献项 + 菜单行。
private struct HostStatusBarHostView: View {
    let manifest: HostStatusBarManifestSnapshot
    let menuBar: (any MenuBarProviding)?
    @LumiUI.LumiTheme private var theme: any LumiUI.LumiUITheme

    var body: some View {
        VStack(spacing: 0) {
            appInfoSection

            if let menuBar {
                HostStatusBarPopupSection(menuBar: menuBar)
            }

            menuItemsSection
        }
        .frame(width: manifest.configuration.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.surface)
    }

    private var appInfoSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.identity.appName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(
                        String(
                            format: String(localized: "v%@", bundle: .module),
                            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var menuItemsSection: some View {
        let items = manifest.configuration.menuItems ?? defaultMenuItems
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider()
                }
                HostMenuItemRow(item: item, prefix: manifest.identity.accessibilityPrefix)
            }
        }
    }

    private var defaultMenuItems: [HostStatusMenuItem] {
        HostStatusBarConfiguration.defaultMenuItems(identity: manifest.identity)
    }
}

private struct HostStatusBarPopupSection: View {
    private let menuBar: any MenuBarProviding
    @StateObject private var refreshModel: MenuBarRefreshModel

    init(menuBar: any MenuBarProviding) {
        self.menuBar = menuBar
        _refreshModel = StateObject(wrappedValue: MenuBarRefreshModel(provider: menuBar))
    }

    var body: some View {
        let items = menuBar.popupItems
        if !items.isEmpty {
            Divider()
            VStack(spacing: 0) {
                ForEach(items) { item in
                    item.makeView()
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
            }
            Divider()
        }
    }
}

/// 弹窗菜单行：打开窗口或执行动作，hover 高亮。
private struct HostMenuItemRow: View {
    let item: HostStatusMenuItem
    let prefix: String
    @State private var isHovering = false

    var body: some View {
        Button {
            if let windowID = item.windowID {
                HostWindowOpener.shared.openWindow(id: windowID)
            }
            item.action?()
        } label: {
            HStack(spacing: 12) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovering ? .white : (item.isDestructive ? Color.red : Color.primary))
                    .padding(.horizontal)
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.accessibilityIdentifier ?? "\(prefix).menu-item")
        .background(Rectangle().fill(isHovering ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear))
        .onHover { isHovering = $0 }
    }
}
#endif