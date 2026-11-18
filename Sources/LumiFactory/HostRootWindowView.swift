import KernelCore
import LumiUI
import ProviderPluginManaging
import ProviderRootView
import ProviderSettingView
import ProviderStorage
import ProviderTheme
import ProviderToast
import SwiftUI
#if os(iOS) || os(visionOS)
import ProviderToolbar
#endif

/// 主窗口壳：启动器三态 → 加载页 / 失败页 / 主视图。
///
/// 与旧代码的关键差异：
/// - 内核由 `KernelBootstrapper` 统一持有（主窗口与设置窗口共享同一实例），
///   不再每个窗口各自创建内核；
/// - 根视图的工具栏 / 入口栏 / 内容在装配期（`KernelAssembler.wireRootView`）
///   已接好，这里的首次组装是**纯读取**，与内核就绪同批落地——避免 Cisum
///   踩过的「.task 组装与首次求值竞态 → 主窗口永远空态」；
/// - 插件启用状态变化时按版本号重新组装，`assemblyToken` 保证子树必然重建。
public struct HostRootWindowView: View {
    @ObservedObject private var bootstrapper: KernelBootstrapper

    public init(bootstrapper: KernelBootstrapper) {
        self.bootstrapper = bootstrapper
    }

    private var manifest: HostManifest { bootstrapper.manifest }

    public var body: some View {
        Group {
            switch bootstrapper.state {
            case .idle, .booting:
                HostLoadingView(
                    appName: manifest.identity.appName,
                    accessibilityPrefix: manifest.identity.accessibilityPrefix
                )
            case .failed(let report):
                HostBootstrapFailureView(
                    failure: report,
                    appName: manifest.identity.appName,
                    dataDirectory: dataDirectory,
                    onRetry: { await bootstrapper.retry() }
                )
            case .ready(let kernel):
                if manifest.features.usesReadyMarkerOverlays {
                    HostMainContentView(kernel: kernel, manifest: manifest)
                        .overlay(alignment: .topLeading) {
                            HostReadyMarker(
                                label: "\(manifest.identity.appName) main window ready",
                                identifier: "\(manifest.identity.accessibilityPrefix).main.ready"
                            )
                        }
                } else {
                    HostMainContentView(kernel: kernel, manifest: manifest)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("\(manifest.identity.accessibilityPrefix).kernel.ready")
                }
            }
        }
        .captureHostWindowOpener()
        .environment(\.toastWindowID, manifest.identity.mainWindowID)
        .task { await bootstrapper.boot() }
    }

    private var dataDirectory: URL {
        manifest.storage.dataRootDirectoryOverride?()
            ?? DefaultStorageProvider.makeDefaultDataRootDirectory()
    }
}

/// 主视图内容：全局背景 + 组装好的根视图 + 平台窗口桥。
private struct HostMainContentView: View {
    private let kernel: KernelCoreContainer
    private let manifest: HostManifest

    @ObservedObject private var themeRegistry = LumiUIThemeRegistry.shared
    @StateObject private var revisionObserver: HostRootRevisionObserver
    @State private var assembledContent: AnyView
    @State private var assemblyToken = 1
    #if os(iOS) || os(visionOS)
    @StateObject private var navigationBarItems: IOSNavigationBarItemsBridge
    #endif

    init(kernel: KernelCoreContainer, manifest: HostManifest) {
        self.kernel = kernel
        self.manifest = manifest
        _revisionObserver = StateObject(wrappedValue: HostRootRevisionObserver(kernel: kernel))
        // 装配期接线已完成，首次组装是纯读取，与内核就绪同批落地。
        _assembledContent = State(initialValue: HostViewAssembly.main(kernel: kernel, manifest: manifest))
        #if os(iOS) || os(visionOS)
        _navigationBarItems = StateObject(
            wrappedValue: IOSNavigationBarItemsBridge(
                provider: kernel.resolveProvider((any IOSNavigationBarProviding).self)
                    ?? DefaultIOSNavigationBarProviding()
            )
        )
        #endif
    }

    var body: some View {
        HostThemedContent(kernel: kernel) {
            GeometryReader { geometry in
                ZStack {
                    themeRegistry.chromeTheme.makeGlobalBackground(proxy: geometry)
                        .ignoresSafeArea()

                    platformContent
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .environment(\.toastProviding, kernel.resolveProvider((any ToastProviding).self))
        #if os(macOS)
        .overlay {
            ZStack {
                ThemeWindowAppearanceBridge().allowsHitTesting(false)
                // 标题不可见时 SwiftUI 会把工具栏项一律降级到前导侧，
                // 这里恢复 placement 语义（保留无标题栏外观）。
                HostToolbarPlacementBridge(accessibilityTitle: manifest.identity.appName)
                    .allowsHitTesting(false)
                if let minimumSize = manifest.identity.mainWindowMinimumSize {
                    HostMinimumSizeBridge(minimumSize: minimumSize)
                        .allowsHitTesting(false)
                }
            }
        }
        #endif
        .task(id: revisionObserver.revision) {
            assembledContent = HostViewAssembly.main(kernel: kernel, manifest: manifest)
            assemblyToken &+= 1
        }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(macOS)
        assembledContent
            .id("\(revisionObserver.revision)-\(assemblyToken)")
            .frame(
                minWidth: manifest.identity.mainWindowMinimumSize?.width,
                minHeight: manifest.identity.mainWindowMinimumSize?.height
            )
        #else
        // makeMainView 提供时表示宿主自带完整主界面（如 Wakey 的 Tab 壳，
        // 设置已是其中一个标签页），不再包 NavigationStack / 设置 sheet；
        // 否则用标准 iOS 设置壳：设置页以 sheet 呈现（openSettings 通知触发），
        // 导航栏项必须挂在 NavigationStack 内部的内容上才会进入这条栈自己的导航栏。
        if manifest.makeMainView != nil {
            assembledContent
                .id("\(revisionObserver.revision)-\(assemblyToken)")
        } else {
            IOSSettingsAppShell(
                title: manifest.identity.appName,
                mainView: AnyView(
                    NavigationStack {
                        assembledContent
                            .id("\(revisionObserver.revision)-\(assemblyToken)")
                            .modifier(IOSNavigationBarToolbarModifier(items: navigationBarItems.items))
                    }
                ),
                settingsView: AnyView(
                    HostThemedContent(kernel: kernel) {
                        HostViewAssembly.settings(kernel: kernel, manifest: manifest)
                    }
                    .environment(\.toastProviding, kernel.resolveProvider((any ToastProviding).self))
                    .environment(\.toastWindowID, manifest.identity.settingsWindowID)
                ),
                navigationBarProvider: kernel.resolveProvider((any IOSNavigationBarProviding).self)
                    ?? DefaultIOSNavigationBarProviding(),
                navigationBarMode: .host
            )
        }
        #endif
    }
}

/// 插件启用状态变化 → 根视图重新组装的版本号来源。
@MainActor
private final class HostRootRevisionObserver: ObservableObject {
    @Published private(set) var revision = 0
    private var handle: (any PluginManagingObserverHandle)?

    init(kernel: KernelCoreContainer) {
        // 句柄由本对象强持有；对象释放后句柄随之释放，provider 的弱引用
        // 自动停止投递（契约规定调用方必须持有句柄）。
        handle = kernel.resolveProvider((any PluginManaging).self)?.addPluginObserver { [weak self] event in
            guard case .enabledStateChanged = event else { return }
            self?.revision += 1
        }
    }
}

/// 主视图 / 设置视图的标准组装（纯读取）。
@MainActor
enum HostViewAssembly {
    static func main(kernel: KernelCoreContainer, manifest: HostManifest) -> AnyView {
        if let makeMainView = manifest.makeMainView {
            return makeMainView(kernel)
        }
        guard let root = kernel.resolveProvider((any RootViewProviding).self) else {
            let fallback = AppEmptyState(
                icon: "square.dashed",
                title: String(localized: "No content", bundle: .module)
            )
            return AnyView(
                fallback.accessibilityIdentifier("\(manifest.identity.accessibilityPrefix).main.window")
            )
        }
        return root.makeRootView()
    }

    static func settings(kernel: KernelCoreContainer, manifest: HostManifest) -> AnyView {
        let view = kernel.resolveProvider((any SettingViewProviding).self)?.makeSettingView()
            ?? AnyView(
                AppEmptyState(
                    icon: "gearshape",
                    title: String(localized: "No settings", bundle: .module)
                )
            )
        // 稳定的窗口内容标识符：侧边栏条目由 LumiSettings 渲染、不带
        // accessibility identifier，UI 测试只能依赖这个锚点。
        // 依赖后代标识的宿主可关闭（id 会传播遮蔽后代自己的标识）。
        guard manifest.features.appliesWindowContentIdentifiers else {
            return view
        }
        return AnyView(
            view.accessibilityIdentifier("\(manifest.identity.accessibilityPrefix).settings.window")
        )
    }
}

/// 1×1 透明就绪标记：给窗口一个稳定的 AX 锚点，又不把标识加在容器上——
/// 容器级 id 会被 SwiftUI 传播给后代，遮蔽后代自己的稳定标识。
struct HostReadyMarker: View {
    let label: String
    let identifier: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

/// 主题包装：有 ThemeProviding 时桥接主题，否则原样返回。
@MainActor
struct HostThemedContent<Content: View>: View {
    private let kernel: KernelCoreContainer
    private let content: Content

    init(kernel: KernelCoreContainer, @ViewBuilder content: () -> Content) {
        self.kernel = kernel
        self.content = content()
    }

    var body: some View {
        if let theme = kernel.resolveProvider((any ProviderTheme.ThemeProviding).self) {
            HostThemeView(theme: theme, content: content)
        } else {
            content
        }
    }
}