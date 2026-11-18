#if os(macOS)
import KernelCore
import ProviderStorage
import ProviderToast
import SwiftUI

/// 设置窗口壳：与主窗口共享同一启动器（同一内核），三态驱动。
///
/// 设置视图**不组合 RootView overlay**：菜单栏 App 的 Window 场景下，
/// overlay 的包装层会让详情区 AX 的 hit point 不稳定（XCTest 随机失败）。
public struct HostSettingsWindowView: View {
    @ObservedObject private var bootstrapper: KernelBootstrapper

    public init(bootstrapper: KernelBootstrapper) {
        self.bootstrapper = bootstrapper
    }

    private var manifest: HostManifest { bootstrapper.manifest }

    public var body: some View {
        Group {
            switch bootstrapper.state {
            case .idle, .booting:
                HostLoadingView(
                    appName: manifest.identity.appName,
                    accessibilityPrefix: manifest.identity.accessibilityPrefix
                )
            case .failed(let report):
                HostBootstrapFailureView(
                    failure: report,
                    appName: manifest.identity.appName,
                    dataDirectory: dataDirectory,
                    onRetry: { await bootstrapper.retry() }
                )
            case .ready(let kernel):
                let content = HostThemedContent(kernel: kernel) {
                    HostViewAssembly.settings(kernel: kernel, manifest: manifest)
                }
                .environment(\.toastProviding, kernel.resolveProvider((any ToastProviding).self))
                if manifest.features.usesReadyMarkerOverlays {
                    content.overlay(alignment: .topLeading) {
                        HostReadyMarker(
                            label: "\(manifest.identity.appName) settings window ready",
                            identifier: "\(manifest.identity.accessibilityPrefix).settings.ready"
                        )
                    }
                } else {
                    content
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("\(manifest.identity.accessibilityPrefix).settings.ready")
                }
            }
        }
        .frame(
            minWidth: manifest.identity.settingsWindowMinimumSize?.width,
            minHeight: manifest.identity.settingsWindowMinimumSize?.height
        )
        .environment(\.toastWindowID, manifest.identity.settingsWindowID)
        .task { await bootstrapper.boot() }
    }

    private var dataDirectory: URL {
        manifest.storage.dataRootDirectoryOverride?()
            ?? DefaultStorageProvider.makeDefaultDataRootDirectory()
    }
}
#endif