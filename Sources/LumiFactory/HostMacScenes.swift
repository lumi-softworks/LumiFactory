#if os(macOS)
import SwiftUI

/// 共享 macOS 场景（单例主窗口 `Window`，菜单栏 App / 单窗口 App 用）。
///
/// 供**嵌套 App 结构体**使用（只提供 scenes）；`@NSApplicationDelegateAdaptor`
/// 必须挂在 @main 根 App 上——SwiftUI 不会安装嵌套 App 上的 adaptor，
/// 这是 Wakey 状态栏 / 设置窗回归的根因。
///
/// 场景拓扑是编译期选择（`SceneBuilder` 不支持条件分支）：需要多窗口
/// `WindowGroup` 的 App 用 `HostMacWindowGroupScenes`。
///
/// 窗口装饰统一为「无标题栏 + 统一工具栏」：工具栏 placement 语义由
/// `HostToolbarPlacementBridge` 在主视图内恢复。
public struct HostMacScenes: Scene {
    private let bootstrapper: KernelBootstrapper

    public init(bootstrapper: KernelBootstrapper) {
        self.bootstrapper = bootstrapper
    }

    public var body: some Scene {
        let identity = bootstrapper.manifest.identity
        Window(identity.appName, id: identity.mainWindowID) {
            HostRootWindowView(bootstrapper: bootstrapper)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: identity.mainWindowDefaultSize.width, height: identity.mainWindowDefaultSize.height)

        HostSettingsAndCommandsScene(bootstrapper: bootstrapper)
    }
}

/// 共享 macOS 场景（多窗口主场景 `WindowGroup`）。
public struct HostMacWindowGroupScenes: Scene {
    private let bootstrapper: KernelBootstrapper

    public init(bootstrapper: KernelBootstrapper) {
        self.bootstrapper = bootstrapper
    }

    public var body: some Scene {
        let identity = bootstrapper.manifest.identity
        WindowGroup(identity.appName, id: identity.mainWindowID) {
            HostRootWindowView(bootstrapper: bootstrapper)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: identity.mainWindowDefaultSize.width, height: identity.mainWindowDefaultSize.height)

        HostSettingsAndCommandsScene(bootstrapper: bootstrapper)
    }
}

/// 设置窗口 + 应用命令（两种主场景拓扑共用）。
private struct HostSettingsAndCommandsScene: Scene {
    let bootstrapper: KernelBootstrapper

    var body: some Scene {
        let identity = bootstrapper.manifest.identity
        Window(String(localized: "Settings", bundle: .module), id: identity.settingsWindowID) {
            HostSettingsWindowView(bootstrapper: bootstrapper)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(
            width: identity.settingsWindowDefaultSize.width,
            height: identity.settingsWindowDefaultSize.height
        )
        .commands {
            HostCommands(bootstrapper: bootstrapper)
        }
    }
}
#endif