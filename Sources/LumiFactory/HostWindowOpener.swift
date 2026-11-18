import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 进程内开窗器：把 SwiftUI 的 `openWindow` 环境动作交给非视图层
/// （AppDelegate / 状态栏宿主）使用。
///
/// 旧 Wakey 用「重试式执行 Cmd+, 菜单动作」开窗：SwiftUI 在 Window 场景
/// 就绪前会静默丢弃菜单动作，只能轮询重试。第一性原理的解法是直接持有
/// 环境动作本身——主窗口出现时捕获（`captureHostWindowOpener()`），
/// 捕获前的请求排队，捕获后立即补发，无需任何轮询。
@MainActor
public final class HostWindowOpener {
    public static let shared = HostWindowOpener()

    private var open: ((String) -> Void)?
    private var pendingIDs: [String] = []

    init() {}

    /// 捕获环境动作（Commands 构建期 / 主窗口 onAppear 时调用），并补发排队请求。
    public func capture(_ open: @escaping (String) -> Void) {
        self.open = open
        let pending = pendingIDs
        pendingIDs.removeAll()
        for id in pending {
            open(id)
        }
    }

    /// 打开指定 id 的窗口；环境动作尚未捕获时先尝试激活已存在的原生窗口，
    /// 窗口也不存在则排队等待捕获后补发。
    public func openWindow(id: String) {
        if let open {
            open(id)
            return
        }
        #if os(macOS)
        if let app = NSApp,
           let window = app.windows.first(where: { $0.identifier?.rawValue == id }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        #endif
        if !pendingIDs.contains(id) {
            pendingIDs.append(id)
        }
    }
}

public extension View {
    /// 在视图出现时把 `openWindow` 环境动作捕获进 `HostWindowOpener`。
    func captureHostWindowOpener() -> some View {
        modifier(HostWindowOpenerCapture())
    }
}

private struct HostWindowOpenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            HostWindowOpener.shared.capture { id in
                action(id: id)
            }
        }
    }
}