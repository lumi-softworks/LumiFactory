#if os(macOS)
import AppKit
import Combine
import KernelCore
import OSLog
import ProviderSettingView
import SwiftUI

/// 共享 macOS 应用代理：兄弟 App 的生命周期差异全部由 `HostManifest` 解释。
///
/// **采用方式**（Wakey 回归的根因修复）：`@NSApplicationDelegateAdaptor`
/// 必须挂在 @main 根 App 上，嵌套 App 结构体上的 adaptor 不会被 SwiftUI 安装。
/// 根 App 在 `init()` 里创建启动器并注入本代理：
///
/// ```swift
/// @main
/// struct MyApp: App {
///     @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
///     @StateObject private var bootstrapper: KernelBootstrapper
///
///     init() {
///         HostAppDelegate.prepareForLaunch()
///         let bootstrapper = KernelBootstrapper(manifest: Self.manifest)
///         _bootstrapper = StateObject(wrappedValue: bootstrapper)
///         appDelegate.bootstrapper = bootstrapper
///     }
///
///     var body: some Scene {
///         MyMacApp(bootstrapper: bootstrapper).body // 嵌套 App 只提供 scenes
///     }
/// }
/// ```
///
/// 与旧代码的关键差异：
/// - 打开设置窗口走 `HostWindowOpener`（捕获 SwiftUI 环境动作 + 排队补发），
///   取代 Wakey 的「重试式执行 Cmd+, 菜单动作」轮询 hack；
/// - 内核异步就绪：状态栏安装与外部路径投递订阅启动器状态，就绪即执行，
///   不再要求 AppDelegate 初始化时内核已同步装配完成。
@MainActor
public final class HostAppDelegate: NSObject, NSApplicationDelegate {
    /// 由根 App 在 `init()` 注入（applicationDidFinishLaunching 之前）。
    public var bootstrapper: KernelBootstrapper? {
        didSet { observeBootstrapper() }
    }

    private var logger = Logger(subsystem: "com.coffic.lumi.factory", category: "delegate")
    private var statusBarController: HostStatusBarController?
    private var openSettingsObserver: (any NSObjectProtocol)?
    private var stateSubscription: AnyCancellable?
    private var pendingExternalURLs: [URL] = []

    public override init() {
        super.init()
    }

    /// 根 App `init()` 调用：禁用窗口状态恢复的持久化。
    ///
    /// 必须在窗口恢复发生之前写入，否则菜单栏 App 的设置窗口会在启动时
    /// 自动出现；启动后再关窗又会触发「最后一个窗口关闭后终止」逻辑。
    public static func prepareForLaunch() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    private var manifest: HostManifest? { bootstrapper?.manifest }

    // MARK: - Application Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard let manifest else {
            logger.error("Bootstrapper not injected before launch; shell features disabled")
            return
        }
        logger = Logger(subsystem: manifest.identity.loggerSubsystem, category: "delegate")
        logger.info("Application did finish launching")

        if manifest.features.statusBar != nil {
            statusBarController = HostStatusBarController(manifest: manifest)
        }
        prepareSettingsWindowSuppressionIfNeeded()
        observeOpenSettingsRequests()
        openMainWindowOnLaunchIfNeeded()
        openSettingsWindowIfRequested()
        observeBootstrapper()

        NotificationCenter.postApplicationDidFinishLaunching()
    }

    /// 显式打开主窗口，不依赖 SwiftUI 首个 `Window` 场景的自动开窗。
    ///
    /// 后台启动（XCTest / 终端直接拉起）时 SwiftUI 的初始开窗是延迟到主队列的
    /// 任务，携带额外启动参数会改变其时序，导致主窗口永不出现（状态栏随之不安装）。
    /// 这里经 `HostWindowOpener` 主动开窗：opener 由 `HostCommands` 在场景构建期
    /// 捕获（早于本回调），捕获前的请求排队补发，开窗确定性地发生。
    private func openMainWindowOnLaunchIfNeeded() {
        guard let manifest, manifest.features.opensMainWindowOnLaunch else { return }
        let mainWindowID = manifest.identity.mainWindowID
        HostWindowOpener.shared.openWindow(id: mainWindowID)
        // 显式开窗不会自动前台化 App；XCTest 启动要求 app 处于 active 状态。
        NSApp?.activate(ignoringOtherApps: true)
        dedupeMainWindowsOnLaunch(id: mainWindowID)
    }

    /// `WindowGroup` 主场景前台启动时 SwiftUI 仍会自动开一个窗（禁用状态恢复
    /// 并不抑制它），与上面的显式开窗叠加出两个主窗口。启动后 2 秒短窗内
    /// 保留首个、关闭其余重复主窗口；短窗结束后不再干预用户主动开多窗口。
    /// 单例 `Window` 场景天然只有一个实例，本逻辑对其无副作用。
    private func dedupeMainWindowsOnLaunch(id: String) {
        Task { @MainActor [weak self] in
            for _ in 0 ..< 40 {
                guard self != nil else { return }
                let matches = NSApp.windows.filter {
                    $0.identifier?.rawValue.contains(id) == true && $0.canBecomeMain
                }
                if matches.count > 1 {
                    for window in matches.dropFirst() {
                        window.close()
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        manifest?.features.quitsWhenLastWindowClosed ?? false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.cleanup()
        if let openSettingsObserver {
            NotificationCenter.default.removeObserver(openSettingsObserver)
        }
        openSettingsObserver = nil
        stateSubscription?.cancel()
        NotificationCenter.postApplicationWillTerminate()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        NotificationCenter.postApplicationDidBecomeActive()
    }

    public func applicationDidResignActive(_ notification: Notification) {
        NotificationCenter.postApplicationDidResignActive()
    }

    // MARK: - State Restoration (disabled)

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    public func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    public func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    // MARK: - Reopen / External Paths

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard manifest?.features.reopensMainWindowOnActivate == true else { return true }
        if !flag, showExistingMainWindow(in: sender) {
            return false
        }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        deliverExternalURLs(urls)
        activateMainWindow()
    }

    public func application(_ application: NSApplication, openFile filename: String) -> Bool {
        deliverExternalURLs([URL(fileURLWithPath: filename)])
        activateMainWindow()
        return true
    }

    /// 外部路径交给宿主的 `openExternalPath` 钩子；内核未就绪时排队，
    /// 就绪后按序补发（取代 Lumi 的 @Published pendingOpenPath 视图消费）。
    private func deliverExternalURLs(_ urls: [URL]) {
        guard manifest?.features.openExternalPath != nil else { return }
        if let kernel = bootstrapper?.kernel {
            for url in urls {
                manifest?.features.openExternalPath?(kernel, url)
            }
        } else {
            pendingExternalURLs.append(contentsOf: urls)
        }
    }

    // MARK: - Bootstrapper Observation

    private func observeBootstrapper() {
        guard let bootstrapper, stateSubscription == nil else { return }
        stateSubscription = bootstrapper.$state.sink { [weak self] state in
            // @Published 变更发生在主线程（bootstrapper 是 MainActor）。
            MainActor.assumeIsolated {
                guard case .ready(let kernel) = state else { return }
                self?.statusBarController?.install(kernel: kernel)
                self?.flushPendingExternalURLs(kernel: kernel)
            }
        }
        if let kernel = bootstrapper.kernel {
            statusBarController?.install(kernel: kernel)
            flushPendingExternalURLs(kernel: kernel)
        }
    }

    private func flushPendingExternalURLs(kernel: KernelCoreContainer) {
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        for url in urls {
            manifest?.features.openExternalPath?(kernel, url)
        }
    }

    // MARK: - Settings Window

    /// 监听插件发来的「打开设置窗口」请求（LumiSettings 标准契约）。
    ///
    /// 在 AppDelegate 中监听而非设置窗口内容视图：菜单栏 App 没有常驻窗口，
    /// 监听器挂在窗口内容上会随窗口关闭被静默丢弃。通知可携带目标入口 id
    /// 用于深链。
    private func observeOpenSettingsRequests() {
        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: SettingViewNavigation.openSettingsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Notification 不是 Sendable：先取值再跨隔离边界。
            let entryID = notification.userInfo?[SettingViewNavigation.entryIDUserInfoKey] as? String
            MainActor.assumeIsolated {
                self?.handleOpenSettingsRequest(entryID: entryID)
            }
        }
    }

    private func handleOpenSettingsRequest(entryID: String?) {
        if let entryID,
           let settings = bootstrapper?.kernel?.resolveProvider((any SettingViewProviding).self) {
            settings.selectEntry(id: entryID)
        }
        guard let settingsWindowID = manifest?.identity.settingsWindowID else { return }
        HostWindowOpener.shared.openWindow(id: settingsWindowID)
    }

    /// UI 测试专用：携带清单声明的启动参数时主动打开设置窗口。
    ///
    /// XCTest 对「无窗口的菜单栏应用」做深层 AX 枚举会无限递归崩溃，
    /// UI 测试统一以「有窗口」状态运行；正常用户启动不受影响。
    private func openSettingsWindowIfRequested() {
        guard let argument = manifest?.features.settingsWindowOpenArgument,
              ProcessInfo.processInfo.arguments.contains(argument),
              let settingsWindowID = manifest?.identity.settingsWindowID else { return }
        HostWindowOpener.shared.openWindow(id: settingsWindowID)
    }

    // MARK: - Settings Window Launch Suppression

    /// SwiftUI 的 `Window` 场景在前台化启动时会自动打开设置窗口，且会在
    /// 启动流程中再次 order front（约 0.4 秒后）——仅 close() 会与 SwiftUI
    /// 拉锯并残留闪烁。压制期采用「alpha=0 不可见 + close」双保险：
    /// 同步首关 + 前 2 秒 50ms 轮询；压制期结束 close 并恢复 alpha=1。
    private func prepareSettingsWindowSuppressionIfNeeded() {
        guard let manifest,
              manifest.features.suppressSettingsWindowOnLaunch else { return }
        if let argument = manifest.features.settingsWindowOpenArgument,
           ProcessInfo.processInfo.arguments.contains(argument) {
            return
        }

        let settingsWindowID = manifest.identity.settingsWindowID
        suppressSettingsWindowAppearance(id: settingsWindowID)

        Task { @MainActor [weak self] in
            for _ in 0 ..< 40 {
                self?.suppressSettingsWindowAppearance(id: settingsWindowID)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.finalizeSettingsWindowSuppression(id: settingsWindowID)
        }
    }

    private func suppressSettingsWindowAppearance(id: String) {
        for window in NSApp.windows where window.identifier?.rawValue == id {
            window.alphaValue = 0
            if window.isVisible { window.close() }
        }
    }

    private func finalizeSettingsWindowSuppression(id: String) {
        for window in NSApp.windows where window.identifier?.rawValue == id {
            if window.isVisible { window.close() }
            window.alphaValue = 1
        }
        logger.info("Settings window launch suppression finished")
    }

    // MARK: - Main Window Activation

    private func showExistingMainWindow(in app: NSApplication) -> Bool {
        guard let manifest else { return false }
        let window = app.windows.first { window in
            (window.isVisible || window.isMiniaturized)
                && window.canBecomeMain
                && window.level == .normal
                && (window.identifier?.rawValue == manifest.identity.mainWindowID
                    || window.title == manifest.identity.appName)
        }
        guard let window else { return false }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func activateMainWindow() {
        guard let manifest else { return }
        let mainWindowID = manifest.identity.mainWindowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == mainWindowID }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
#endif