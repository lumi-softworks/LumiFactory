#if os(macOS)
import AppKit
import SwiftUI

/// 把 SwiftUI 布局最小值同步到原生 macOS 窗口。
///
/// `frame(minWidth:)` 只约束视图层级，不更新 `NSWindow.contentMinSize`；
/// 没有原生值，窗口仍可被拖到实际布局最小值以下。
public struct HostMinimumSizeBridge: NSViewRepresentable {
    public let minimumSize: CGSize

    public init(minimumSize: CGSize) {
        self.minimumSize = minimumSize
    }

    public static func apply(to window: NSWindow, minimumSize: CGSize) {
        guard minimumSize.width.isFinite, minimumSize.height.isFinite else { return }

        // 全尺寸内容窗口的 content rect 含工具栏；预留这部分高度，
        // 内容区才能拿到完整的最小高度。
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let toolbarHeight = max(0, currentContentSize.height - window.contentLayoutRect.height)
        let minimumContentSize = CGSize(
            width: minimumSize.width,
            height: minimumSize.height + toolbarHeight
        )
        window.contentMinSize = minimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size

        guard currentContentSize.width < minimumContentSize.width
            || currentContentSize.height < minimumContentSize.height else { return }

        window.setContentSize(
            CGSize(
                width: max(currentContentSize.width, minimumContentSize.width),
                height: max(currentContentSize.height, minimumContentSize.height)
            )
        )
    }

    public func makeNSView(context: Context) -> HostMinimumSizeView {
        HostMinimumSizeView(minimumSize: minimumSize)
    }

    public func updateNSView(_ nsView: HostMinimumSizeView, context: Context) {
        nsView.minimumSize = minimumSize
        nsView.applyMinimumSize()
    }
}

public final class HostMinimumSizeView: NSView {
    var minimumSize: CGSize
    private var observedWindow: NSWindow?
    // 只在主线程（NSView 生命周期）读写；deinit 需要访问它移除观察者。
    nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
    private var isApplyingMinimumSize = false

    init(minimumSize: CGSize) {
        self.minimumSize = minimumSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()
        applyMinimumSize()
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    private func updateWindowObservation() {
        guard window !== observedWindow else { return }

        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }

        observedWindow = window
        guard let window else { return }

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyMinimumSize()
        }
    }

    func applyMinimumSize() {
        guard !isApplyingMinimumSize,
              let window,
              minimumSize.width.isFinite,
              minimumSize.height.isFinite else { return }

        isApplyingMinimumSize = true
        defer { isApplyingMinimumSize = false }

        HostMinimumSizeBridge.apply(to: window, minimumSize: minimumSize)
    }
}

/// macOS 窗口工具栏落位修正桥。
///
/// SwiftUI 的 `ToolbarItem(placement:)` 要落到标题栏尾随侧，前提是窗口标题
/// **可见**；`titleVisibility = .hidden`（来自 `.hiddenTitleBar` 或
/// `.unified(showsTitle: false)`）会把所有 placement 一律降级到前导侧。
///
/// 本桥保留「无标题栏」外观（透明标题栏、无分隔线、无标题文字），同时把
/// `titleVisibility` 修正回 `.visible` 恢复 placement 语义；窗口的无障碍
/// 标题单独保留（VoiceOver / XCUITest / Window 菜单仍读得到 App 名）。
///
/// 窗口装饰属于宿主职责：插件只声明 placement，宿主让声明生效。
@MainActor
public struct HostToolbarPlacementBridge: NSViewRepresentable {
    private let accessibilityTitle: String?

    public init(accessibilityTitle: String? = nil) {
        self.accessibilityTitle = accessibilityTitle
    }

    public func makeNSView(context: Context) -> NSView {
        let view = HostToolbarPlacementHostView()
        view.updateAccessibilityTitle(accessibilityTitle)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? HostToolbarPlacementHostView else { return }
        host.updateAccessibilityTitle(accessibilityTitle)
        host.applyPlacement()
    }
}

private final class HostToolbarPlacementHostView: NSView {
    private var titleForAccessibility: String?

    func updateAccessibilityTitle(_ title: String?) {
        guard titleForAccessibility != title else { return }
        titleForAccessibility = title
        applyPlacement()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPlacement()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPlacement()
    }

    /// 幂等：重复调用无副作用。
    func applyPlacement() {
        guard let window else { return }

        // 先恢复标题可见性（placement 依赖它），再处理文字与装饰。
        if window.titleVisibility != .visible {
            window.titleVisibility = .visible
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }

        // SwiftUI 会用 Scene 标题回填 window.title，每次重新置空。
        if !window.title.isEmpty {
            window.title = ""
        }
        // NSWindow 自身的 accessibilityTitle() 方法遮蔽了协议可写属性，
        // 必须用 setAccessibilityTitle(_:)。
        if let titleForAccessibility, window.accessibilityTitle() != titleForAccessibility {
            window.setAccessibilityTitle(titleForAccessibility)
        }
    }
}
#endif