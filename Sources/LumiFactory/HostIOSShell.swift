#if os(iOS) || os(visionOS)
import Combine
import ProviderSettingView
import ProviderToolbar
import SwiftUI

/// iOS 设置外壳：设置页以 sheet 呈现（iOS 没有独立的设置窗口 Scene）。
///
/// 呈现链路：插件把齿轮贡献到 `IOSNavigationBarProviding` → 点击广播
/// `SettingViewNavigation.openSettingsNotification` → 本外壳监听并弹出
/// 设置 sheet。
///
/// 导航栏归属由 `navigationBarMode` 决定：
/// - `.host`（推荐）：宿主拥有 `NavigationStack`，导航栏项由宿主用
///   `IOSNavigationBarItemsBridge` 在**栈内内容上**挂载（SwiftUI 不会把
///   外层 `.toolbar` 传递进嵌套导航栈）。外壳不自绘导航条，避免双导航栏。
/// - `.overlay`：宿主没有系统导航栈时，外壳自绘 48pt 导航条承载贡献项。
@MainActor
public struct IOSSettingsAppShell: View {
    public enum NavigationBarMode: Sendable {
        case host
        case overlay
    }

    private let title: String
    private let mainView: AnyView
    private let settingsView: AnyView
    private let navigationBarProvider: any IOSNavigationBarProviding
    private let navigationBarMode: NavigationBarMode

    @State private var isSettingsPresented = false

    public init(
        title: String,
        mainView: AnyView,
        settingsView: AnyView,
        navigationBarProvider: any IOSNavigationBarProviding,
        navigationBarMode: NavigationBarMode = .overlay
    ) {
        self.title = title
        self.mainView = mainView
        self.settingsView = settingsView
        self.navigationBarProvider = navigationBarProvider
        self.navigationBarMode = navigationBarMode
    }

    public var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: SettingViewNavigation.openSettingsNotification)) { _ in
                isSettingsPresented = true
            }
            .sheet(isPresented: $isSettingsPresented) {
                settingsView
                    // 设置根页是「页面选择器 + 列表」，半屏高度会挤掉分组、
                    // 搜索框和条目，因此固定全屏（仍可下拉关闭）。
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch navigationBarMode {
        case .host:
            mainView
        case .overlay:
            VStack(spacing: 0) {
                IOSNavigationBarHost(title: title, provider: navigationBarProvider)
                mainView
            }
        }
    }
}

/// iOS 导航栏贡献项桥接器：把 `IOSNavigationBarProviding` 的可见项转成
/// 可直接挂到导航栈上的 `[AnyView]`。只负责「取值 + 变更转发」，
/// 挂载位置由宿主决定（必须在 NavigationStack 内部的内容上）。
@MainActor
public final class IOSNavigationBarItemsBridge: ObservableObject {
    private let provider: any IOSNavigationBarProviding
    private var observation: AnyCancellable?

    public init(provider: any IOSNavigationBarProviding) {
        self.provider = provider
        observation = provider.objectWillChange.sink { [weak self] _ in
            // 只转发变更信号：真正的取值发生在宿主渲染时（此时 provider
            // 的新值已经生效），避免在 objectWillChange 阶段读到旧值。
            self?.objectWillChange.send()
        }
    }

    /// 当前可见的导航栏项，按 order 升序（相同 order 时按 id 稳定排序）。
    public var items: [AnyView] {
        provider.visibleNavigationBarItems
            .sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
            }
            .map { $0.makeView() }
    }
}

/// 把导航栏贡献项挂到系统导航栏的 modifier。
///
/// 必须挂在 `NavigationStack` **内部的内容**上：挂在栈自身之后，项会被
/// 算到外层上下文，表现为「贡献成功但看不见」。
@MainActor
public struct IOSNavigationBarToolbarModifier: ViewModifier {
    private let items: [AnyView]

    public init(items: [AnyView]) {
        self.items = items
    }

    public func body(content: Content) -> some View {
        if items.isEmpty {
            content
        } else {
            content.toolbar {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ToolbarItem(placement: .topBarTrailing) {
                        item
                    }
                }
            }
        }
    }
}

/// 自绘导航条宿主（仅 `.overlay` 模式）：不依赖系统 `.toolbar`，
/// 避免不同 NavigationStack 宿主下工具栏不显示。
@MainActor
public struct IOSNavigationBarHost: View {
    public let title: String
    @StateObject private var providerAdapter: IOSNavigationBarProviderAdapter

    public init(title: String, provider: any IOSNavigationBarProviding) {
        self.title = title
        _providerAdapter = StateObject(
            wrappedValue: IOSNavigationBarProviderAdapter(provider: provider)
        )
    }

    public var body: some View {
        let items = providerAdapter.visibleNavigationBarItems
        let leading = items.filter { $0.placement == .leading }
        let principal = items.filter { $0.placement == .principal }
        let trailing = items.filter { $0.placement == .trailing }

        HStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(leading) { item in
                    item.makeView()
                        .accessibilityLabel(item.title)
                }
            }

            Spacer(minLength: 0)

            if principal.isEmpty {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    ForEach(principal) { item in
                        item.makeView()
                            .accessibilityLabel(item.title)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ForEach(trailing) { item in
                    item.makeView()
                        .accessibilityLabel(item.title)
                }
            }
            .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

@MainActor
private final class IOSNavigationBarProviderAdapter: ObservableObject {
    private let provider: any IOSNavigationBarProviding
    private var observation: AnyCancellable?

    init(provider: any IOSNavigationBarProviding) {
        self.provider = provider
        observation = provider.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var visibleNavigationBarItems: [IOSNavigationBarItem] {
        provider.visibleNavigationBarItems
    }
}
#endif