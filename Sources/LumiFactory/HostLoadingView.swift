import LumiUI
import SwiftUI

/// 内核启动加载视图（品牌无关的通用版）。
///
/// 两处关键设计（来自 Cisum 的教训）：
///
/// **背景必须与主界面同源。** 加载页直接复用主界面的全局背景
/// （`chromeTheme.makeGlobalBackground`），两者必然一致，不会出现
/// 「加载页暗 → 主界面亮」的明暗闪烁。
///
/// **内容延迟露出。** 内核启动通常只需百毫秒量级，此时展示任何加载页
/// 都只是让用户看到一次闪烁。品牌标记与文案延迟 400ms 才出现：启动够快，
/// 这一屏根本不会出现；启动确实慢，它才作为「有内容的等待」发挥作用。
/// 背景始终立即绘制，保证窗口不会是一片空白。
public struct HostLoadingView: View {
    private static let contentRevealDelay = Duration.milliseconds(400)

    private let appName: String
    private let accessibilityPrefix: String
    private let brandOverlay: AnyView?

    @ObservedObject private var themeRegistry = LumiUIThemeRegistry.shared
    @LumiTheme private var theme
    @LumiMotionPreferenceReader private var motionPreference

    private enum Stage: Int, CaseIterable {
        case starting
        case loadingPlugins
        case preparingInterface

        var message: String {
            switch self {
            case .starting: String(localized: "Starting…", bundle: .module)
            case .loadingPlugins: String(localized: "Loading plugins…", bundle: .module)
            case .preparingInterface: String(localized: "Preparing the interface…", bundle: .module)
            }
        }
    }

    @State private var stage: Stage = .starting
    @State private var revealsContent = false
    @State private var stageTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?

    public init(appName: String, accessibilityPrefix: String, brandOverlay: AnyView? = nil) {
        self.appName = appName
        self.accessibilityPrefix = accessibilityPrefix
        self.brandOverlay = brandOverlay
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 兜底底色：主题尚未注册时全局背景是全透明的，
                // 没有这一层窗口会是一片空白。
                startupBackdrop
                    .ignoresSafeArea()

                themeRegistry.chromeTheme.makeGlobalBackground(proxy: geometry)
                    .ignoresSafeArea()

                if revealsContent {
                    content
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix).kernel.loading")
        .onAppear { startSequence() }
        .onDisappear {
            stageTask?.cancel()
            revealTask?.cancel()
        }
    }

    /// 跟随系统的中性窗口底色：起点不与终点（浅色或深色主题）相斥。
    private var startupBackdrop: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #elseif canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        theme.background
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: AppUI.Spacing.xl) {
                brand
                labels
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppUI.Spacing.xl)
    }

    private var brand: some View {
        HostLoadingBrandView(overlay: brandOverlay)
    }

    private var labels: some View {
        VStack(spacing: AppUI.Spacing.sm) {
            Text(appName)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            Text(stage.message)
                .font(AppUI.Typography.caption1)
                .foregroundStyle(theme.textSecondary)
                .contentTransition(.opacity)
                .animation(
                    motionPreference.allowsMotion ? .easeInOut(duration: 0.25) : nil,
                    value: stage
                )
        }
    }

    private func startSequence() {
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: Self.contentRevealDelay)
            guard !Task.isCancelled else { return }
            revealsContent = true
        }

        stageTask = Task { @MainActor in
            let schedule: [(Stage, Duration)] = [
                (.loadingPlugins, .milliseconds(260)),
                (.preparingInterface, .milliseconds(520))
            ]
            for (next, delay) in schedule {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                stage = next
            }
        }
    }
}

/// 加载页品牌区：柔光 + 旋转进度环 + 可选的宿主品牌标记叠加层。
///
/// 无时序状态，可独立渲染（单测用 ImageRenderer 验证叠加层契约）。
struct HostLoadingBrandView: View {
    var overlay: AnyView?

    @LumiTheme private var theme
    @Environment(\.colorScheme) private var colorScheme
    @LumiMotionPreferenceReader private var motionPreference

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.primary.opacity(colorScheme == .dark ? 0.34 : 0.22), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 90
                    )
                )
                .frame(width: 190, height: 190)
                .blur(radius: 6)

            progressRing

            if let overlay {
                overlay
            }
        }
        .frame(width: 190, height: 190)
    }

    /// 围绕品牌标记旋转的渐变光环。
    private var progressRing: some View {
        TimelineView(.animation) { context in
            let angle = motionPreference.allowsMotion
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360
                : 0.0

            Circle()
                .trim(from: 0.06, to: 0.94)
                .stroke(
                    AngularGradient(
                        colors: [
                            theme.primary.opacity(0.05),
                            theme.primary.opacity(0.35),
                            theme.primary.opacity(0.95),
                            theme.primarySecondary.opacity(0.9),
                            theme.primary.opacity(0.05)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 168, height: 168)
                .rotationEffect(.degrees(angle))
                .opacity(motionPreference.allowsMotion ? 1 : 0.55)
        }
    }
}