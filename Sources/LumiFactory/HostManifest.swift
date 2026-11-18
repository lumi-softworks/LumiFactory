import Foundation
import KernelCore
import WorkbenchRootView
import ProviderRootView
import ProviderTheme
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 宿主清单：一个 App 与共享装配引擎之间的全部差异。
///
/// 「功能是数据，应用是解释器」——兄弟 App 不再各自维护 Factory，
/// 只提供一份清单：品牌身份、插件清单、存储/主题配置、兼容映射与少量钩子。
/// 装配流水线（基线 Provider → 迁移 → 启动 → 接线）由 `KernelAssembler` 统一解释。
///
/// 钩子的边界：
/// - `registerProviders`：注册 App 域 Provider（AppState / Cloud / 播放引擎等），
///   在插件 boot 之前执行；
/// - `wireKernel`：启动完成后的 App 域接线（显隐协调、场景订阅、对话绑定等），
///   在共享接线（工具栏 / 入口栏 / 设置重置）之后执行。
public struct HostManifest {
    public var identity: HostIdentity
    public var makePlugins: @MainActor () -> [any SuperPlugin]
    /// 插件白名单过滤（对齐 Cisum `SelectedPluginFactory`）；nil 表示全量装配。
    public var pluginFilter: (@MainActor (any SuperPlugin) -> Bool)?
    public var storage: HostStorageConfiguration
    public var theme: HostThemeConfiguration
    /// 新插件 id → 旧插件 id，交给内核做启用状态读写兼容（升级不丢开关、回滚仍生效）。
    public var legacyPluginIDAliases: [String: String]
    /// 默认根视图的布局配置（工具栏 / ActivityBar / 空态文案）。
    /// 仅在 `makeRootViewProvider` 为 nil 时生效。
    public var rootViewLayout: RootViewLayoutConfiguration
    /// 根视图 Provider 注入：需要完全自定义布局（如 Workbench 三栏）时由宿主
    /// 提供。nil 时使用共享的 `FactoryRootViewProviding(layout: rootViewLayout)`。
    public var makeRootViewProvider: (@MainActor () -> any RootViewProviding)?
    public var registerProviders: (@MainActor (KernelCoreContainer) throws -> Void)?
    public var wireKernel: (@MainActor (KernelCoreContainer) -> Void)?
    /// 主视图组装钩子（需要完全自定义主界面时提供，如播放器布局 / iOS Tab 壳）。
    ///
    /// **必须是纯读取**：在 SwiftUI 视图初始化期调用，写入 Provider 会触发
    /// "Publishing changes from within view updates"。装配期写入请放 `wireKernel`。
    /// nil 时使用标准组装：`RootViewProviding.makeRootView()`（工具栏 / 入口栏 /
    /// 内容已由装配流水线接好）。
    ///
    /// iOS 上提供本钩子即表示宿主自带完整壳（含导航与设置入口），
    /// 标准 `IOSSettingsAppShell`（NavigationStack + 设置 sheet）不再包裹。
    public var makeMainView: (@MainActor (KernelCoreContainer) -> AnyView)?
    public var features: HostFeatures

    public init(
        identity: HostIdentity,
        makePlugins: @escaping @MainActor () -> [any SuperPlugin],
        pluginFilter: (@MainActor (any SuperPlugin) -> Bool)? = nil,
        storage: HostStorageConfiguration,
        theme: HostThemeConfiguration = HostThemeConfiguration(),
        legacyPluginIDAliases: [String: String] = [:],
        rootViewLayout: RootViewLayoutConfiguration = .minimal,
        makeRootViewProvider: (@MainActor () -> any RootViewProviding)? = nil,
        registerProviders: (@MainActor (KernelCoreContainer) throws -> Void)? = nil,
        wireKernel: (@MainActor (KernelCoreContainer) -> Void)? = nil,
        makeMainView: (@MainActor (KernelCoreContainer) -> AnyView)? = nil,
        features: HostFeatures = HostFeatures()
    ) {
        self.identity = identity
        self.makePlugins = makePlugins
        self.pluginFilter = pluginFilter
        self.storage = storage
        self.theme = theme
        self.legacyPluginIDAliases = legacyPluginIDAliases
        self.rootViewLayout = rootViewLayout
        self.makeRootViewProvider = makeRootViewProvider
        self.registerProviders = registerProviders
        self.wireKernel = wireKernel
        self.makeMainView = makeMainView
        self.features = features
    }
}

/// 品牌身份与窗口契约。
///
/// 窗口 id 与 AX 前缀是 UI 测试的稳定锚点，一旦发布不可随意更改。
public struct HostIdentity {
    public var appName: String
    public var loggerSubsystem: String
    public var mainWindowID: String
    public var settingsWindowID: String
    /// AX 标识前缀（如 `wakey`）：主窗口内容 `<prefix>.main.window`、
    /// 设置窗口 `<prefix>.settings.window`、工具栏设置按钮 `<prefix>.toolbar.settings`。
    public var accessibilityPrefix: String
    public var mainWindowMinimumSize: CGSize?
    public var settingsWindowMinimumSize: CGSize?
    /// 窗口默认尺寸（首次打开时生效，用户调整后由系统记忆）。
    public var mainWindowDefaultSize: CGSize
    public var settingsWindowDefaultSize: CGSize

    public init(
        appName: String,
        loggerSubsystem: String,
        mainWindowID: String,
        settingsWindowID: String,
        accessibilityPrefix: String,
        mainWindowMinimumSize: CGSize? = nil,
        settingsWindowMinimumSize: CGSize? = nil,
        mainWindowDefaultSize: CGSize = CGSize(width: 1000, height: 760),
        settingsWindowDefaultSize: CGSize = CGSize(width: 960, height: 560)
    ) {
        self.appName = appName
        self.loggerSubsystem = loggerSubsystem
        self.mainWindowID = mainWindowID
        self.settingsWindowID = settingsWindowID
        self.accessibilityPrefix = accessibilityPrefix
        self.mainWindowMinimumSize = mainWindowMinimumSize
        self.settingsWindowMinimumSize = settingsWindowMinimumSize
        self.mainWindowDefaultSize = mainWindowDefaultSize
        self.settingsWindowDefaultSize = settingsWindowDefaultSize
    }
}

/// 存储配置：数据根、启用状态存储键、历史目录迁移表。
public struct HostStorageConfiguration {
    /// 插件启用状态存放目录所用的插件 id（通常是插件管理插件的 id）。
    public var stateStorePluginID: String
    /// 数据根覆盖（UI 测试隔离等）；nil 时使用
    /// `DefaultStorageProvider.makeDefaultDataRootDirectory()`。
    public var dataRootDirectoryOverride: (@MainActor () -> URL?)?
    /// 插件 id → 历史目录名序列（按时间从旧到新）。
    /// 在 Provider 创建前执行基础设施级迁移（启用状态、主题选择等装配期就要读的数据）。
    public var legacyDirectoryMigrations: [String: [String]]

    public init(
        stateStorePluginID: String,
        dataRootDirectoryOverride: (@MainActor () -> URL?)? = nil,
        legacyDirectoryMigrations: [String: [String]] = [:]
    ) {
        self.stateStorePluginID = stateStorePluginID
        self.dataRootDirectoryOverride = dataRootDirectoryOverride
        self.legacyDirectoryMigrations = legacyDirectoryMigrations
    }
}

/// 主题配置：内置白名单、目录白名单、选择存储目录。
public struct HostThemeConfiguration {
    /// 内置主题白名单；nil 表示 `BuiltinThemes.all` 全量。
    public var builtinThemeIDs: [String]?
    /// 共享目录主题白名单；nil 表示不在装配期预注册目录主题
    /// （仍可由宿主挂载 ThemePackPlugin 自行注册）。
    ///
    /// 预注册发生在内核启动**之前**：加载页的背景取自全局主题注册中心，
    /// 晚注册会造成启动瞬间的明暗闪烁（Cisum 教训）。
    public var catalogThemeIDs: [String]?
    /// 主题选择文件的存储目录名（跨 App 共享同一目录可延续用户选择）。
    public var storageDirectoryName: String
    /// 旧主题选择键迁移（如 Cisum 的 UserDefaults 旧键），在目录注册后执行。
    public var migrateLegacySelection: (@MainActor (any ThemeProviding) -> Void)?

    public init(
        builtinThemeIDs: [String]? = nil,
        catalogThemeIDs: [String]? = nil,
        storageDirectoryName: String = "com.coffic.lumi.plugin.theme-manager",
        migrateLegacySelection: (@MainActor (any ThemeProviding) -> Void)? = nil
    ) {
        self.builtinThemeIDs = builtinThemeIDs
        self.catalogThemeIDs = catalogThemeIDs
        self.storageDirectoryName = storageDirectoryName
        self.migrateLegacySelection = migrateLegacySelection
    }
}

/// 宿主壳的功能开关与配置。
public struct HostFeatures {
    /// macOS 状态栏入口；nil 表示不安装状态栏项。
    public var statusBar: HostStatusBarConfiguration?
    /// 启动时显式打开主窗口（普通 App 为 true）。
    ///
    /// 不依赖 SwiftUI 首个 `Window` 场景的自动开窗——后台启动时该行为不可靠。
    /// 纯菜单栏 App（启动只驻留状态栏、不开主窗口）设为 false。
    public var opensMainWindowOnLaunch: Bool
    /// 主窗口工具栏右侧的宿主设置按钮（发 `lumi.openSettings` 通知，由壳打开窗口）。
    public var showsSettingsToolbarButton: Bool
    /// Dock 图标点击 / 无窗口时重新打开主窗口（applicationShouldHandleReopen）。
    public var reopensMainWindowOnActivate: Bool
    /// 外部路径打开（文件 / 目录）；nil 表示不处理。
    public var openExternalPath: (@MainActor (KernelCoreContainer, URL) -> Void)?
    /// 「检查更新…」菜单动作；nil 表示不显示该菜单项。
    public var checkForUpdates: (@MainActor @Sendable () -> Void)?
    /// 关闭最后一个窗口后是否退出。菜单栏 App 必须为 false（关窗后驻留状态栏）。
    public var quitsWhenLastWindowClosed: Bool
    /// 启动期压制自动弹出的设置窗口（SwiftUI `Window` 场景前台化启动会自动开窗）。
    /// 菜单栏 App 开启；有常驻主窗口的 App 不需要。
    public var suppressSettingsWindowOnLaunch: Bool
    /// UI 测试专用启动参数：携带时跳过设置窗压制并主动打开设置窗口
    /// （无窗口的菜单栏应用会让 XCTest 的 AX 枚举无限递归）。
    public var settingsWindowOpenArgument: String?
    /// 是否给窗口内容加 AX 标识（`<prefix>.main.window` / `<prefix>.settings.window`）。
    ///
    /// SwiftUI 会把内容级 id 传播给后代，遮蔽后代自己的稳定标识；
    /// UI 测试依赖大量后代标识的宿主（如 GitOK）应设为 false，
    /// 并配合 `usesReadyMarkerOverlays` 提供窗口就绪锚点。
    public var appliesWindowContentIdentifiers: Bool
    /// 用 1×1 透明 overlay 作为窗口就绪标记（`<prefix>.main.ready` /
    /// `<prefix>.settings.ready`），替代容器级 `kernel.ready` / `settings.ready`
    /// 标识。容器级标识同样会传播遮蔽后代，故与
    /// `appliesWindowContentIdentifiers = false` 搭配使用。
    public var usesReadyMarkerOverlays: Bool

    public init(
        statusBar: HostStatusBarConfiguration? = nil,
        opensMainWindowOnLaunch: Bool = true,
        showsSettingsToolbarButton: Bool = true,
        reopensMainWindowOnActivate: Bool = true,
        openExternalPath: (@MainActor (KernelCoreContainer, URL) -> Void)? = nil,
        checkForUpdates: (@MainActor @Sendable () -> Void)? = nil,
        quitsWhenLastWindowClosed: Bool = false,
        suppressSettingsWindowOnLaunch: Bool = false,
        settingsWindowOpenArgument: String? = nil,
        appliesWindowContentIdentifiers: Bool = true,
        usesReadyMarkerOverlays: Bool = false
    ) {
        self.statusBar = statusBar
        self.opensMainWindowOnLaunch = opensMainWindowOnLaunch
        self.showsSettingsToolbarButton = showsSettingsToolbarButton
        self.reopensMainWindowOnActivate = reopensMainWindowOnActivate
        self.openExternalPath = openExternalPath
        self.checkForUpdates = checkForUpdates
        self.quitsWhenLastWindowClosed = quitsWhenLastWindowClosed
        self.suppressSettingsWindowOnLaunch = suppressSettingsWindowOnLaunch
        self.settingsWindowOpenArgument = settingsWindowOpenArgument
        self.appliesWindowContentIdentifiers = appliesWindowContentIdentifiers
        self.usesReadyMarkerOverlays = usesReadyMarkerOverlays
    }
}

/// macOS 状态栏配置（MenuBarHostKit 参数 + 弹窗菜单行）。
public struct HostStatusBarConfiguration {
    public var statusViewHeight: CGFloat
    public var popoverWidth: CGFloat
    public var popoverMaximumHeight: CGFloat
    public var activatesApplication: Bool
    /// 状态栏图标视图；nil 时从 LogoProviding 取 `.statusBar` 场景视图。
    public var makeIconView: (@MainActor (KernelCoreContainer) -> AnyView)?
    /// 弹窗底部菜单行；nil 时使用默认三行（主窗口 / 设置 / 退出）。
    public var menuItems: [HostStatusMenuItem]?

    public init(
        statusViewHeight: CGFloat = 20,
        popoverWidth: CGFloat = 300,
        popoverMaximumHeight: CGFloat = 800,
        activatesApplication: Bool = true,
        makeIconView: (@MainActor (KernelCoreContainer) -> AnyView)? = nil,
        menuItems: [HostStatusMenuItem]? = nil
    ) {
        self.statusViewHeight = statusViewHeight
        self.popoverWidth = popoverWidth
        self.popoverMaximumHeight = popoverMaximumHeight
        self.activatesApplication = activatesApplication
        self.makeIconView = makeIconView
        self.menuItems = menuItems
    }

    /// 默认三行菜单：主窗口（标题为 App 名）/ 设置 / 退出。
    ///
    /// 文案取本包资源；宿主需要品牌化首行（如「设备信息…」）时，
    /// 取本数组后替换对应项即可，AX 契约与退出动作保持一致。
    #if os(macOS)
    @MainActor
    public static func defaultMenuItems(identity: HostIdentity) -> [HostStatusMenuItem] {
        [
            HostStatusMenuItem(
                title: identity.appName,
                windowID: identity.mainWindowID,
                accessibilityIdentifier: "\(identity.accessibilityPrefix).statusbar.main"
            ),
            HostStatusMenuItem(
                title: String(localized: "Settings...", bundle: .module),
                windowID: identity.settingsWindowID,
                accessibilityIdentifier: "\(identity.accessibilityPrefix).statusbar.settings"
            ),
            HostStatusMenuItem(
                title: String(localized: "Quit", bundle: .module),
                accessibilityIdentifier: "\(identity.accessibilityPrefix).statusbar.quit",
                isDestructive: true,
                action: { NSApp.terminate(nil) }
            ),
        ]
    }
    #endif
}

/// 状态栏弹窗菜单行：打开窗口或执行动作。
public struct HostStatusMenuItem {
    public var title: String
    public var windowID: String?
    public var accessibilityIdentifier: String?
    public var isDestructive: Bool
    public var action: (@MainActor () -> Void)?

    public init(
        title: String,
        windowID: String? = nil,
        accessibilityIdentifier: String? = nil,
        isDestructive: Bool = false,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.windowID = windowID
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isDestructive = isDestructive
        self.action = action
    }
}