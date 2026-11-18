#if !os(macOS)
import KernelCore
import ProviderSettingView
import SwiftUI
import UIKit
import UserNotifications

/// 移动端 Tab 壳的一个内容标签页。
///
/// 标签页是数据：标题 / 图标由宿主声明，内容视图经闭包注入（通常是业务
/// 插件的弹窗视图升级为整页）。壳本身不依赖任何业务插件。
public struct HostMobileTab: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let makeContent: @MainActor () -> AnyView

    public init(
        id: String,
        title: String,
        systemImage: String,
        makeContent: @escaping @MainActor () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.makeContent = makeContent
    }
}

/// 兄弟 App 共享的 iOS / iPadOS 主界面：底部标签页承载内容页与设置。
///
/// iOS 没有菜单栏常驻入口，宿主把功能页声明为 `HostMobileTab`，壳负责：
/// - 每页 NavigationStack + ScrollView 布局（iPad 上限宽 720，避免卡片通栏）；
/// - 通知权限被拒时的提示横幅（背景提醒静默失效的唯一回显）；
/// - 末尾追加设置页（消费 `SettingViewProviding` 的入口列表，与 macOS
///   设置窗口共用同一批入口与详情实现）；
/// - 记住上次停留的标签页（存储键由宿主声明，重开回到原标签）。
@MainActor
public struct HostMobileTabShell: View {
    private let kernel: KernelCoreContainer
    private let tabs: [HostMobileTab]
    private let appName: String
    @AppStorage private var selectedTabID: String

    public init(
        kernel: KernelCoreContainer,
        tabs: [HostMobileTab],
        appName: String,
        selectedTabStorageKey: String
    ) {
        self.kernel = kernel
        self.tabs = tabs
        self.appName = appName
        _selectedTabID = AppStorage(
            wrappedValue: tabs.first?.id ?? Self.settingsTabID,
            selectedTabStorageKey
        )
    }

    private static let settingsTabID = "settings"

    /// 存储的标签 id 可能已不在当前清单里（插件被下线）：回退到首个标签。
    private var selection: Binding<String> {
        Binding(
            get: {
                tabs.contains { $0.id == selectedTabID } || selectedTabID == Self.settingsTabID
                    ? selectedTabID
                    : (tabs.first?.id ?? Self.settingsTabID)
            },
            set: { selectedTabID = $0 }
        )
    }

    public var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                mobileTab(tab: tab)
            }
            HostMobileSettingsList(kernel: kernel)
                .tabItem {
                    Label(
                        String(localized: "Settings", bundle: .module),
                        systemImage: "gearshape"
                    )
                }
                .tag(Self.settingsTabID)
        }
    }

    private func mobileTab(tab: HostMobileTab) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    tab.makeContent()
                    HostNotificationPermissionBanner(appName: appName)
                }
                .padding(.horizontal)
                // iPad 上不限宽的话弹窗卡片会被拉成通栏，观感与 macOS 弹窗差异过大。
                .frame(maxWidth: 720)
            }
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tabItem { Label(tab.title, systemImage: tab.systemImage) }
        .tag(tab.id)
    }
}

/// 通知权限被拒后的提示。
///
/// 本地通知是 iOS 上 App 退到后台后唯一的提醒通道；用户在系统弹窗点了
/// 「不允许」时不会有任何回显，没有这条提示就等于背景提醒静默失效。
@MainActor
private struct HostNotificationPermissionBanner: View {
    let appName: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(spacing: 8) {
            if authorizationStatus == .denied {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications are off", bundle: .module)
                            .font(.footnote.weight(.semibold))
                        Text(String(
                            format: String(
                                localized: "%@ can only remind you while it is open. Turn on notifications to get reminders in the background.",
                                bundle: .module
                            ),
                            appName
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button(String(localized: "Open Settings", bundle: .module)) {
                        openSystemSettings()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshAuthorization() }
        }
    }

    private func refreshAuthorization() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

/// iOS 设置页：直接消费 `SettingViewProviding` 的入口列表。
///
/// 插件在内核启动时把入口注入共享 Provider，这里按 `order` 排序列出并
/// 推入各自详情视图——与 macOS 设置窗口共用同一批入口与详情实现。
@MainActor
private struct HostMobileSettingsList: View {
    let kernel: KernelCoreContainer
    @StateObject private var observer: SettingsEntriesObserver

    init(kernel: KernelCoreContainer) {
        self.kernel = kernel
        _observer = StateObject(
            wrappedValue: SettingsEntriesObserver(
                provider: kernel.resolveProvider((any SettingViewProviding).self)
            )
        )
    }

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                NavigationLink {
                    entry.makeDetailView()
                        .navigationTitle(entry.title)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(entry.title, systemImage: entry.systemImage)
                }
            }
            .navigationTitle(String(localized: "Settings", bundle: .module))
        }
    }

    private var entries: [SettingEntryItem] {
        (observer.provider?.entries ?? []).sorted { $0.order < $1.order }
    }
}

@MainActor
private final class SettingsEntriesObserver: ObservableObject {
    let provider: (any SettingViewProviding)?
    private var handle: (any SettingViewObserverHandle)?

    init(provider: (any SettingViewProviding)?) {
        self.provider = provider
        handle = provider?.addSettingViewObserver { [weak self] event in
            guard case .entriesChanged = event else { return }
            self?.objectWillChange.send()
        }
    }
}
#endif