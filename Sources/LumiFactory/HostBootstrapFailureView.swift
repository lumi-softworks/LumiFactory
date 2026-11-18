import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 内核装配失败时的兜底视图。
///
/// - Important: 此视图在内核装配失败后渲染，必须**完全自足**：
///   不得使用 `@LumiTheme` / `AppUI.*` 等依赖 ThemeProviding 解析结果的
///   LumiUI 组件，否则主题 Provider 缺失会二次崩溃，导致连错误页都显示不出来。
///   因此这里只使用 SwiftUI 语义色与 SF Symbols。
public struct HostBootstrapFailureView: View {
    private let failure: BootstrapFailureReport
    private let appName: String
    private let dataDirectory: URL
    private let onRetry: (@MainActor () async -> Void)?

    /// 技术详情默认是否展开。
    ///
    /// 磁盘不足时标题已经说清了「该做什么」，原始报错收起来；其余情况仍然
    /// 默认展开，保持「一键看到原始报错」的老行为。
    @State private var showsTechnicalDetail: Bool

    public init(
        failure: BootstrapFailureReport,
        appName: String,
        dataDirectory: URL,
        onRetry: (@MainActor () async -> Void)? = nil
    ) {
        self.failure = failure
        self.appName = appName
        self.dataDirectory = dataDirectory
        self.onRetry = onRetry
        _showsTechnicalDetail = State(initialValue: {
            switch failure.kind {
            case .insufficientDiskSpace: return false
            case .pluginBootFailed, .unknown: return true
            }
        }())
    }

    public var body: some View {
        VStack(spacing: 24) {
            badge

            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)

            explanation

            actions

            technicalDetails
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 标题按归因结果分级：磁盘不足要说「磁盘空间不足」，而不是「启动失败」。
    private var title: String {
        switch failure.kind {
        case .insufficientDiskSpace:
            return String(localized: "Insufficient Disk Space", bundle: .module)
        case .pluginBootFailed:
            return String(localized: "Plugin Failed to Start", bundle: .module)
        case .unknown:
            return String(
                format: String(localized: "%@ Failed to Start", bundle: .module),
                appName
            )
        }
    }

    private var explanation: some View {
        Text(explanationText)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460, alignment: .leading)
    }

    private var explanationText: String {
        switch failure.kind {
        case .insufficientDiskSpace(let availableBytes, let requiredBytes):
            return String(
                format: String(
                    localized: "%1$@ needs at least %2$@ of free disk space to start. Only %3$@ remains. Free up disk space and restart — the data directory often contains large files you can clean up.",
                    bundle: .module
                ),
                appName,
                BootstrapByteFormat.string(requiredBytes),
                BootstrapByteFormat.string(availableBytes)
            )
        case .pluginBootFailed:
            let plugin = failure.pluginID.map { "\"\($0)\"" }
                ?? String(localized: "a plugin", bundle: .module)
            return String(
                format: String(
                    localized: "Plugin %1$@ failed during the %2$@ phase. The original error is in the technical details below; copy it to investigate.",
                    bundle: .module
                ),
                plugin,
                failure.phase ?? "boot"
            )
        case .unknown:
            return String(
                localized: "An unexpected error occurred during startup. The original error is in the technical details below; copy it to investigate.",
                bundle: .module
            )
        }
    }

    /// 可操作动作。内核此时还没装配成功，不能依赖任何 Provider，
    /// 动作全部走 AppKit / Foundation。
    private var actions: some View {
        HStack(spacing: 12) {
            switch failure.kind {
            case .insufficientDiskSpace:
                #if os(macOS)
                Button(String(localized: "Open Data Directory in Finder", bundle: .module)) {
                    openDataDirectory()
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Restart", bundle: .module)) {
                    relaunch()
                }
                .buttonStyle(.bordered)
                #endif
                Button(String(localized: "Quit", bundle: .module)) {
                    terminateApp()
                }
                .buttonStyle(.bordered)
            case .pluginBootFailed, .unknown:
                if let onRetry {
                    Button(String(localized: "Retry", bundle: .module)) {
                        Task { await onRetry() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(String(localized: "Copy Technical Details", bundle: .module)) {
                    copyTechnicalDetail()
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Quit", bundle: .module)) {
                    terminateApp()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetail) {
            detailCard
        } label: {
            Label(String(localized: "Technical Details", bundle: .module), systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pluginID = failure.pluginID {
                Text(String(format: String(localized: "Plugin: %@", bundle: .module), pluginID))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let phase = failure.phase {
                Text(String(format: String(localized: "Phase: %@", bundle: .module), phase))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(failure.technicalDetail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    // MARK: - 动作实现

    private func openDataDirectory() {
        #if os(macOS)
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(dataDirectory)
        #endif
    }

    private func relaunch() {
        #if os(macOS)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        #endif
    }

    private func terminateApp() {
        #if os(macOS)
        NSApp.terminate(nil)
        #endif
    }

    private func copyTechnicalDetail() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(failure.technicalDetail, forType: .string)
        #else
        UIPasteboard.general.string = failure.technicalDetail
        #endif
    }

    private var badge: some View {
        ZStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 132))
                .foregroundStyle(.orange.opacity(0.10))
                .blur(radius: 10)
                .offset(y: 4)
                .allowsHitTesting(false)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.orange, Color.red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 96, height: 96)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .red.opacity(0.28), radius: 18, y: 8)

            Image(systemName: "exclamationmark")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}