import Foundation
import KernelCore
import LumiThemePack
import OSLog
import ProviderActivityBar
import ProviderContentView
import ProviderDiskCache
import ProviderDocsView
import ProviderLogo
import ProviderPluginControl
import ProviderPluginManaging
import ProviderRootView
import ProviderSettingView
import ProviderStorage
import ProviderTheme
import ProviderToast
import ProviderToolbar
import SwiftUI
#if os(macOS)
import ProviderMenuBar
#endif

/// 共享装配流水线：把 `HostManifest` 解释成一个已启动的内核。
///
/// 唯一的一条 boot 路径（async）——旧代码里 sync/async 双路径长期漂移，
/// 同步版拒绝 AsyncSuperPlugin、异步版漏接线，这里统一收敛：
///
/// ```
/// legacyAliases → 存储根 + 基础设施目录迁移
///   → 基线 Host Provider（root/settings/logo/theme/工具栏或导航栏/存储/状态存储/插件管理/toast/磁盘缓存）
///   → 主题目录预注册（早于 start，防加载页明暗闪烁）
///   → App 域 Provider 钩子
///   → 插件清单 + 白名单过滤 + 逐插件隔离迁移
///   → startAsync
///   → 设置首入口重置 → 根视图接线（Workbench 宿主可通过 features 跳过）→ App 域接线钩子
/// ```
@MainActor
public enum KernelAssembler {
    nonisolated static let logger = Logger(subsystem: "com.coffic.lumi.factory", category: "assembler")

    /// 装配期登记的观察者句柄（按内核持有，shutdown 时统一取消）。
    private static var retainedHandles: [ObjectIdentifier: [AnyObject]] = [:]

    /// 创建并启动内核。失败时抛出原始错误，归因由 `KernelBootstrapper` 负责。
    public static func makeKernel(manifest: HostManifest) async throws -> KernelCoreContainer {
        let kernel = KernelCoreContainer()

        // 启用状态兼容映射必须在任何插件 boot 之前配置。
        kernel.legacyPluginIDAliases = manifest.legacyPluginIDAliases

        let storage = DefaultStorageProvider(
            dataRootDirectory: manifest.storage.dataRootDirectoryOverride?()
        )
        HostPluginMigration.migrateInfrastructure(
            storage: storage,
            migrations: manifest.storage.legacyDirectoryMigrations,
            logger: logger
        )

        try registerBaselineProviders(kernel: kernel, manifest: manifest, storage: storage)

        // 主题目录预注册必须早于 start：加载页背景取自全局主题注册中心。
        if let theme = kernel.resolveProvider((any ProviderTheme.ThemeProviding).self) {
            if let catalogIDs = manifest.theme.catalogThemeIDs {
                LumiThemeRegistration.register(in: theme, themeIDs: catalogIDs)
            }
            manifest.theme.migrateLegacySelection?(theme)
        }

        try manifest.registerProviders?(kernel)

        var plugins = manifest.makePlugins()
        if let filter = manifest.pluginFilter {
            plugins = plugins.filter(filter)
        }
        HostPluginMigration.migratePlugins(plugins, storage: storage, logger: logger)

        try await kernel.startAsync(plugins: plugins)
        logger.info("Kernel started with \(plugins.count) plugins")

        resetSettingsSelectionToFirstEntry(kernel: kernel)
        #if os(macOS)
        if !manifest.features.skipsSharedRootViewWiring {
            wireRootView(kernel: kernel, manifest: manifest)
        }
        #endif
        manifest.wireKernel?(kernel)

        return kernel
    }

    /// 释放装配期登记的观察者句柄（内核销毁时调用）。
    static func releaseHandles(for kernel: KernelCoreContainer) {
        let handles = retainedHandles.removeValue(forKey: ObjectIdentifier(kernel)) ?? []
        for handle in handles {
            (handle as? any ActivityBarObserverHandle)?.cancel()
        }
    }

    // MARK: - Baseline Providers

    /// 基线 Provider：跨 App 完全一致的宿主基础设施。
    ///
    /// 根视图是 **host provider** 而非插件——它由宿主拥有、插件向其贡献，
    /// 旧代码用 RootViewPlugin 注册基础设施混淆了所有权，这里纠正。
    private static func registerBaselineProviders(
        kernel: KernelCoreContainer,
        manifest: HostManifest,
        storage: any StorageProviding
    ) throws {
        let root = manifest.makeRootViewProvider?()
            ?? FactoryRootViewProviding(layout: manifest.rootViewLayout)
        try kernel.registerHostProvider((any RootViewProviding).self, root)
        try kernel.registerHostProvider((any SettingViewProviding).self, DefaultSettingViewProviding())
        try kernel.registerHostProvider(LogoProviding.self, DefaultLogoProviding())

        var builtinThemes = ProviderTheme.BuiltinThemes.all
        if let whitelist = manifest.theme.builtinThemeIDs {
            builtinThemes = builtinThemes.filter { whitelist.contains($0.id) }
        }
        try kernel.registerHostProvider(
            (any ProviderTheme.ThemeProviding).self,
            ProviderTheme.DefaultThemeProviding(
                builtinThemes: builtinThemes,
                defaultStorageDirectoryName: manifest.theme.storageDirectoryName
            )
        )

        #if os(macOS)
        try kernel.registerHostProvider(MenuBarProviding.self, DefaultMenuBarProviding())
        try kernel.registerHostProvider((any ContentViewProviding).self, DefaultContentViewProviding())
        try kernel.registerHostProvider((any ActivityBarProviding).self, DefaultActivityBarProviding())
        try kernel.registerHostProvider((any ToolbarProviding).self, DefaultToolbarProviding())
        #else
        // iOS 没有窗口工具栏，设置入口挂在系统导航栏。
        try kernel.registerHostProvider(
            (any IOSNavigationBarProviding).self,
            DefaultIOSNavigationBarProviding()
        )
        #endif

        try kernel.registerProvider((any DocsViewProviding).self, DefaultDocsViewProviding())
        try kernel.registerProvider((any StorageProviding).self, storage)
        kernel.stateStore = PluginEnabledStateStore(
            pluginDirectory: storage.pluginDataDirectory(for: manifest.storage.stateStorePluginID)
        )

        // 可删除磁盘缓存：独立于数据根（系统可回收，不参与迁移）。
        try kernel.registerProvider((any DiskCacheProviding).self, DefaultDiskCacheProvider())

        // Toast 默认实现必须先于插件 boot 存在；ToastSuperPlugin 随后替换为真实实现。
        try kernel.registerProvider((any ToastProviding).self, DefaultToastProviding())

        // 插件管理：PluginControlling 与 PluginManaging 共享同一内核状态。
        try kernel.registerProvider((any PluginControlling).self, DefaultPluginControlling(kernel: kernel))
        let controlling = kernel.resolveProvider((any PluginControlling).self)
            ?? DefaultPluginControlling(kernel: kernel)
        try kernel.registerProvider(
            (any PluginManaging).self,
            DefaultPluginManager(kernel: kernel, controlling: controlling)
        )
    }

    // MARK: - Post-start Wiring

    /// 默认选中 order 最小的设置入口。
    ///
    /// 首个 addEntries 的插件会把选中态锁定为当时的唯一入口——这是注册顺序
    /// 副作用，与「默认选中第一个」的设计意图不符。全部入口就位后重置；
    /// 本次运行内的用户选择不受影响。
    private static func resetSettingsSelectionToFirstEntry(kernel: KernelCoreContainer) {
        guard let settings = kernel.resolveProvider((any SettingViewProviding).self),
              let firstID = settings.entries.first?.id,
              settings.selectedEntryID != firstID
        else { return }
        settings.selectEntry(id: firstID)
    }

    #if os(macOS)
    /// 把工具栏 / 入口栏 / 主内容接到根视图（装配期调用一次）。
    ///
    /// 贡献字段是 `@Published`，必须在装配期写入而非 SwiftUI body 求值期，
    /// 否则触发 "Publishing changes from within view updates"。
    private static func wireRootView(kernel: KernelCoreContainer, manifest: HostManifest) {
        guard let rootView = kernel.resolveProvider((any RootViewProviding).self) else {
            logger.error("RootViewProviding not registered; main window falls back to empty content")
            return
        }

        if let toolbar = kernel.resolveProvider((any ToolbarProviding).self) {
            if manifest.features.showsSettingsToolbarButton {
                toolbar.addToolbarItems([
                    HostToolbarSettings.makeItem(prefix: manifest.identity.accessibilityPrefix)
                ])
            }
            rootView.setToolbarView(toolbar.makeToolbarView())
        }

        // 共享包的 ActivityBarView 只在入口栏可见时才注册观察者，「启动时一个
        // 入口、之后启用第二个插件」不会自动出现入口栏。入口数量变化时重挂视图，
        // 并以数量作为视图标识强制 SwiftUI 换身份重新渲染。
        if let activityBar = kernel.resolveProvider((any ActivityBarProviding).self) {
            func makeActivityBarView() -> AnyView {
                AnyView(activityBar.makeActivityBarView().id(activityBar.items.count))
            }
            rootView.setActivityBarView(makeActivityBarView())
            let handle = activityBar.addActivityBarObserver { event in
                guard case .itemsChanged = event else { return }
                rootView.setActivityBarView(makeActivityBarView())
            }
            retainedHandles[ObjectIdentifier(kernel), default: []].append(handle)
        }

        if let content = kernel.resolveProvider((any ContentViewProviding).self) {
            let contentView = content.makeContentView()
            rootView.setContentView(
                manifest.features.appliesWindowContentIdentifiers
                    ? AnyView(
                        contentView.accessibilityIdentifier(
                            "\(manifest.identity.accessibilityPrefix).main.window"
                        )
                    )
                    : AnyView(contentView)
            )
        }
    }
    #endif
}