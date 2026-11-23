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
            menuBar: menuBar,
            menuBarHost: menuBarHost
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
///
/// 插件数量多时贡献区会很长，整体高度不能无限增长：头部与底部菜单保持自然
/// 高度，只有贡献区在剩余空间内滚动。宿主弹窗尺寸由 `MenuBarHost.setContentHeight`
/// 显式控制，这里必须把插件区约束在可用高度内，否则自然高度会把底部菜单
/// 挤出可视区域。
private struct HostStatusBarHostView: View {
    let manifest: HostStatusBarManifestSnapshot
    let menuBar: (any MenuBarProviding)?
    let menuBarHost: MenuBarHost
    @LumiUI.LumiTheme private var theme: any LumiUI.LumiUITheme
    @State private var headerHeight: CGFloat = 0
    @State private var menuHeight: CGFloat = 0
    @State private var pluginContentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            appInfoSection
                .background(HeightReporter { headerHeight = $0 })

            if let menuBar {
                HostStatusBarPopupSection(
                    menuBar: menuBar,
                    width: manifest.configuration.popoverWidth,
                    isScrollable: pluginContentHeight > pluginBudget + 0.5
                ) { pluginContentHeight = $0 }
                    .frame(height: pluginDisplayHeight)
            }

            menuItemsSection
                .background(HeightReporter { menuHeight = $0 })
        }
        .frame(width: manifest.configuration.popoverWidth)
        .background(theme.surface)
        .onChange(of: preferredHeight, initial: true) { _, height in
            guard height > 0 else { return }
            menuBarHost.setContentHeight(height)
        }
    }

    /// 弹窗总高度上限：配置值与当前屏幕可用高度的较小者。
    ///
    /// `visibleFrame` 已排除菜单栏和 Dock；再留 32pt 给弹窗箭头与边距，
    /// 避免在小屏幕上仍然顶出屏幕。
    private var maximumHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visibleHeight = (screen?.visibleFrame.height ?? 900) - 32
        return min(manifest.configuration.popoverMaximumHeight, visibleHeight)
    }

    /// 插件贡献区可用高度：总上限扣掉固定的头部与底部菜单。
    private var pluginBudget: CGFloat {
        max(160, maximumHeight - headerHeight - menuHeight)
    }

    /// 插件贡献区显示高度：内容短时按内容高度，内容长时固定为可用高度并内部滚动。
    ///
    /// 内容高度首次由内部真实布局回报；回报前保持 0，避免先撑高再收缩。
    private var pluginDisplayHeight: CGFloat {
        guard pluginContentHeight > 0 else { return 0 }
        return min(pluginContentHeight, pluginBudget)
    }

    private var pluginIsEmpty: Bool {
        menuBar?.popupItems.isEmpty ?? true
    }

    /// 弹窗应有的自然高度（不超过上限），交给宿主设置弹窗尺寸。
    private var preferredHeight: CGFloat {
        guard headerHeight > 0, menuHeight > 0 else { return 0 }
        return headerHeight + (pluginIsEmpty ? 0 : pluginDisplayHeight) + menuHeight
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
    private let width: CGFloat
    private let isScrollable: Bool
    private let onContentHeight: (CGFloat) -> Void
    @LumiUI.LumiTheme private var theme: any LumiUI.LumiUITheme
    @StateObject private var refreshModel: MenuBarRefreshModel
    @State private var hasContentAbove = false
    @State private var hasContentBelow = false

    init(
        menuBar: any MenuBarProviding,
        width: CGFloat,
        isScrollable: Bool,
        onContentHeight: @escaping (CGFloat) -> Void
    ) {
        self.menuBar = menuBar
        self.width = width
        self.isScrollable = isScrollable
        self.onContentHeight = onContentHeight
        _refreshModel = StateObject(wrappedValue: MenuBarRefreshModel(provider: menuBar))
    }

    var body: some View {
        let items = menuBar.popupItems
        if !items.isEmpty {
            VStack(spacing: 0) {
                Divider()
                ScrollView(.vertical) {
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
                    // 纵向 ScrollView 不向内容传递可用宽度，插件项的固有宽度
                    // 会把内容撑得比弹窗宽、再被居中裁剪。这里显式钉住宽度，
                    // 让插件按弹窗宽度布局，横向滚动留给插件自己处理。
                    .frame(width: width)
                    .background(HeightReporter(onChange: onContentHeight))
                }
                .modifier(ScrollEdgeReporter { above, below in
                    hasContentAbove = above
                    hasContentBelow = below
                })
                .overlay(alignment: .top) {
                    scrollFade(edge: .top, visible: hasContentAbove)
                }
                .overlay(alignment: .bottom) {
                    scrollFade(edge: .bottom, visible: hasContentBelow, showsChevron: true)
                }
                .onChange(of: isScrollable, initial: true) { _, scrollable in
                    // macOS 15+ 由滚动几何驱动，这里不要重置：首次布局时
                    // `isScrollable` 还是 false，重置会把已算好的边缘状态清掉，
                    // 而几何值未变化时不会再回调，提示就永远不出现。
                    if #unavailable(macOS 15.0) {
                        hasContentAbove = false
                        hasContentBelow = scrollable
                    }
                }
                Divider()
            }
        }
    }

    /// 滚动区边缘渐隐：内容被裁切时提示还可以继续滚动。
    @ViewBuilder
    private func scrollFade(edge: VerticalEdge, visible: Bool, showsChevron: Bool = false) -> some View {
        let isBottom = edge == .bottom
        LinearGradient(
            colors: [theme.surface.opacity(0), theme.surface],
            startPoint: isBottom ? .top : .bottom,
            endPoint: isBottom ? .bottom : .top
        )
        .frame(height: 20)
        .overlay(alignment: .bottom) {
            if showsChevron {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 1)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: visible)
        .allowsHitTesting(false)
    }
}

/// 滚动区上下边缘是否还有内容，用于驱动渐隐提示。
private struct ScrollEdgeReporter: ViewModifier {
    let onChange: (_ above: Bool, _ below: Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                ScrollEdges(
                    above: geometry.contentOffset.y > 1,
                    below: geometry.contentOffset.y + geometry.containerSize.height
                        < geometry.contentSize.height - 1
                )
            } action: { _, edges in
                onChange(edges.above, edges.below)
            }
        } else {
            content
        }
    }
}

private struct ScrollEdges: Equatable {
    var above: Bool
    var below: Bool
}

/// 把 SwiftUI 子树的真实布局高度回报给调用方。
///
/// 宿主按显式尺寸撑开弹窗，`GeometryReader` 偏好值在此场景下会拿到 0，
/// 这里改由 AppKit 视图的真实 bounds 回报。
private struct HeightReporter: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.onChange = onChange
    }

    final class ReportingView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var reportedHeight: CGFloat?

        override func layout() {
            super.layout()
            let height = bounds.height
            guard height > 0 else { return }
            if let reportedHeight, abs(reportedHeight - height) < 0.5 { return }
            reportedHeight = height
            let callback = onChange
            DispatchQueue.main.async { callback?(height) }
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