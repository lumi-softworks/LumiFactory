import Foundation
import LumiUI
import ProviderSettingView
import ProviderToolbar
import SwiftUI

/// 主窗口工具栏右侧的宿主设置按钮。
///
/// 点击发出共享的「打开设置」通知（`lumi.openSettings`），由宿主壳的
/// delegate 监听并打开设置窗口——插件与工具栏都无需知道窗口由谁持有。
/// 这取代了旧 Wakey 里「重试式 Cmd+,」的开窗 hack。
@MainActor
enum HostToolbarSettings {
    static func makeItem(prefix: String) -> ProviderToolbar.ToolbarItem {
        ProviderToolbar.ToolbarItem(
            id: "settings",
            title: String(localized: "Settings", bundle: .module, comment: "Tooltip for the toolbar settings button"),
            placement: .trailing,
            category: .global,
            order: 300
        ) {
            AppIconButton(systemImage: "gearshape") {
                NotificationCenter.default.post(
                    name: SettingViewNavigation.openSettingsNotification,
                    object: nil
                )
            }
            .accessibilityIdentifier("\(prefix).toolbar.settings")
        }
    }

    #if !os(macOS)
    /// iOS / visionOS 导航栏右侧的宿主设置按钮。
    ///
    /// 与 macOS 工具栏齿轮同一语义：点击发出「打开设置」通知，
    /// 由标准 iOS 设置壳（`IOSSettingsAppShell`）监听并弹出设置 sheet。
    static func makeIOSItem(prefix: String) -> ProviderToolbar.IOSNavigationBarItem {
        ProviderToolbar.IOSNavigationBarItem(
            id: "settings",
            title: String(localized: "Settings", bundle: .module, comment: "Accessibility label for the navigation bar settings button"),
            placement: .trailing,
            category: .global,
            order: 300
        ) {
            Button {
                NotificationCenter.default.post(
                    name: SettingViewNavigation.openSettingsNotification,
                    object: nil
                )
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(
                String(localized: "Settings", bundle: .module, comment: "Accessibility label for the navigation bar settings button")
            )
            .accessibilityIdentifier("\(prefix).navigation-bar.settings")
        }
    }
    #endif
}