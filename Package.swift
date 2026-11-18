// swift-tools-version: 6.0
// LumiFactory: 兄弟 App 共享的宿主装配引擎与窗口壳（Composition Root as a Package）。
//
// 设计原则：
// - 功能是数据，应用是解释器：App 只提供 HostManifest（插件清单 + 品牌配置 + 钩子），
//   装配流水线、窗口壳、启动失败归因全部由本包解释执行。
// - 只依赖契约与基础设施（KernelCore / Provider* / LumiUI / LumiThemePack / LumiSettings，
//   以及根视图基础设施 WorkbenchRootView 的 ConfigurableRootViewProviding），
//   不依赖任何业务插件包——插件由宿主经 manifest.makePlugins 注入。
import PackageDescription

let package = Package(
    name: "LumiFactory",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LumiFactory", targets: ["LumiFactory"])
    ],
    dependencies: [
        .package(url: "https://github.com/lumi-softworks/LumiKernel.git", from: "1.1.0"),
        .package(url: "https://github.com/lumi-softworks/LumiProviders.git", from: "1.26.0"),
        .package(url: "https://github.com/lumi-softworks/LumiUI.git", from: "1.13.1"),
        .package(url: "https://github.com/lumi-softworks/LumiThemePack.git", from: "1.0.12"),
        .package(url: "https://github.com/lumi-softworks/LumiSettings.git", from: "1.1.0"),
        // 1.3.0 起模块改名 WorkbenchRootView（核心 API 不变）；JuiceNote 等
        // Workbench 宿主需要 1.3.x 的 Overlay 宿主与重复注入去重修复。
        .package(url: "https://github.com/lumi-softworks/LumiPluginRootView.git", from: "1.3.2"),
    ],
    targets: [
        .target(
            name: "LumiFactory",
            dependencies: [
                .product(name: "KernelCore", package: "LumiKernel"),
                .product(name: "LumiUI", package: "LumiUI"),
                .product(name: "LumiThemePack", package: "LumiThemePack"),
                .product(name: "ProviderSettingView", package: "LumiSettings"),
                .product(name: "ProviderActivityBar", package: "LumiProviders"),
                .product(name: "ProviderCommand", package: "LumiProviders"),
                .product(name: "ProviderContentView", package: "LumiProviders"),
                .product(name: "ProviderDiskCache", package: "LumiProviders"),
                .product(name: "ProviderDocsView", package: "LumiProviders"),
                .product(name: "ProviderLogo", package: "LumiProviders"),
                .product(name: "ProviderMenuBar", package: "LumiProviders"),
                .product(name: "MenuBarHostKit", package: "LumiProviders"),
                .product(name: "ProviderPluginControl", package: "LumiProviders"),
                .product(name: "ProviderPluginManaging", package: "LumiProviders"),
                .product(name: "ProviderRootView", package: "LumiProviders"),
                .product(name: "ProviderStorage", package: "LumiProviders"),
                .product(name: "ProviderTheme", package: "LumiProviders"),
                .product(name: "ProviderToast", package: "LumiProviders"),
                .product(name: "ProviderToolbar", package: "LumiProviders"),
                .product(name: "WorkbenchRootView", package: "LumiPluginRootView"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LumiFactoryTests",
            dependencies: [
                "LumiFactory",
                .product(name: "KernelCore", package: "LumiKernel"),
                .product(name: "ProviderStorage", package: "LumiProviders"),
                .product(name: "ProviderRootView", package: "LumiProviders"),
                .product(name: "ProviderTheme", package: "LumiProviders"),
                .product(name: "ProviderToast", package: "LumiProviders"),
                .product(name: "ProviderPluginManaging", package: "LumiProviders"),
                .product(name: "ProviderLogo", package: "LumiProviders"),
                .product(name: "ProviderSettingView", package: "LumiSettings"),
                .product(name: "WorkbenchRootView", package: "LumiPluginRootView"),
            ]
        ),
    ]
)