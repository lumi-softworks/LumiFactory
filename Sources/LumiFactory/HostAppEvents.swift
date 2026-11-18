import SwiftUI

// MARK: - 应用生命周期与状态栏事件
//
// 通知名是跨包契约（远程插件按这些 raw value 广播），不可更改。
// 旧代码里 Wakey/Cisum 各自定义同名扩展，接入 LumiFactory 后删除 App 侧副本。

public extension Notification.Name {
    /// 应用启动完成。
    static let applicationDidFinishLaunching = Notification.Name("applicationDidFinishLaunching")
    /// 应用即将终止。
    static let applicationWillTerminate = Notification.Name("applicationWillTerminate")
    /// 应用变为活跃状态。
    static let applicationDidBecomeActive = Notification.Name("applicationDidBecomeActive")
    /// 应用变为非活跃状态。
    static let applicationDidResignActive = Notification.Name("applicationDidResignActive")
    /// 请求更新状态栏外观。userInfo: ["isActive": Bool, "source": String]
    static let requestStatusBarAppearanceUpdate = Notification.Name("requestStatusBarAppearanceUpdate")
    /// 请求更新状态栏网速显示。userInfo: ["uploadSpeed": Double, "downloadSpeed": Double, "source": String]
    static let requestStatusBarSpeedUpdate = Notification.Name("requestStatusBarSpeedUpdate")
    /// 请求更新休息提醒状态。userInfo: ["isActive": Bool, "type": String?]
    static let requestBreakReminderStatusUpdate = Notification.Name("requestBreakReminderStatusUpdate")
}

public extension NotificationCenter {
    static func postApplicationDidFinishLaunching(object: Any? = nil) {
        NotificationCenter.default.post(name: .applicationDidFinishLaunching, object: object)
    }

    static func postApplicationWillTerminate(object: Any? = nil) {
        NotificationCenter.default.post(name: .applicationWillTerminate, object: object)
    }

    static func postApplicationDidBecomeActive(object: Any? = nil) {
        NotificationCenter.default.post(name: .applicationDidBecomeActive, object: object)
    }

    static func postApplicationDidResignActive(object: Any? = nil) {
        NotificationCenter.default.post(name: .applicationDidResignActive, object: object)
    }

    static func postRequestStatusBarAppearanceUpdate(isActive: Bool, source: String) {
        NotificationCenter.default.post(
            name: .requestStatusBarAppearanceUpdate,
            object: nil,
            userInfo: ["isActive": isActive, "source": source]
        )
    }

    static func postRequestStatusBarSpeedUpdate(uploadSpeed: Double, downloadSpeed: Double, source: String) {
        NotificationCenter.default.post(
            name: .requestStatusBarSpeedUpdate,
            object: nil,
            userInfo: ["uploadSpeed": uploadSpeed, "downloadSpeed": downloadSpeed, "source": source]
        )
    }

    static func postRequestBreakReminderStatusUpdate(isActive: Bool, type: String?) {
        var userInfo: [String: Any] = ["isActive": isActive]
        if let type {
            userInfo["type"] = type
        }
        NotificationCenter.default.post(
            name: .requestBreakReminderStatusUpdate,
            object: nil,
            userInfo: userInfo
        )
    }
}

public extension View {
    func onApplicationDidFinishLaunching(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .applicationDidFinishLaunching)) { _ in
            action()
        }
    }

    func onApplicationWillTerminate(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .applicationWillTerminate)) { _ in
            action()
        }
    }

    func onApplicationDidBecomeActive(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .applicationDidBecomeActive)) { _ in
            action()
        }
    }

    func onApplicationDidResignActive(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .applicationDidResignActive)) { _ in
            action()
        }
    }

    func onStatusBarSpeedUpdate(perform action: @escaping (_ uploadSpeed: Double, _ downloadSpeed: Double) -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .requestStatusBarSpeedUpdate)) { notification in
            guard let userInfo = notification.userInfo,
                  let upload = userInfo["uploadSpeed"] as? Double,
                  let download = userInfo["downloadSpeed"] as? Double else {
                return
            }
            action(upload, download)
        }
    }

    func onBreakReminderStatusUpdate(perform action: @escaping (_ isActive: Bool, _ type: String?) -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .requestBreakReminderStatusUpdate)) { notification in
            guard let userInfo = notification.userInfo,
                  let isActive = userInfo["isActive"] as? Bool else {
                return
            }
            let type = userInfo["type"] as? String
            action(isActive, type)
        }
    }
}