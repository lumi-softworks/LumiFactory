import Foundation
import KernelCore
import OSLog
import ProviderStorage
import SwiftUI

/// 宿主启动器：内核生命周期的唯一持有者，三态驱动窗口壳。
///
/// 旧代码的三种启动形态（Lumi 同步装配 + 失败页、Wakey 同步装配、
/// Cisum 幂等内核注册表 + 异步装配）收敛为一个 `@StateObject`：
///
/// - `booting`：壳渲染加载页；
/// - `ready(kernel)`：壳渲染主视图；
/// - `failed(report)`：壳渲染可操作的失败页（重试 / 复制详情 / 打开数据目录）。
///
/// 幂等：重复 `boot()` 不重建内核；`retry()` 仅在失败后重建。
@MainActor
public final class KernelBootstrapper: ObservableObject {
    public enum State {
        case idle
        case booting
        case ready(KernelCoreContainer)
        case failed(BootstrapFailureReport)
    }

    @Published public private(set) var state: State = .idle

    public let manifest: HostManifest
    private let logger: Logger

    public init(manifest: HostManifest) {
        self.manifest = manifest
        self.logger = Logger(subsystem: manifest.identity.loggerSubsystem, category: "bootstrap")
    }

    /// 当前已就绪的内核（未就绪时为 nil）。
    public var kernel: KernelCoreContainer? {
        if case .ready(let kernel) = state { return kernel }
        return nil
    }

    /// 启动内核（幂等）。预检 → 装配 → 三态落位。
    public func boot() async {
        switch state {
        case .booting, .ready:
            return
        case .idle, .failed:
            break
        }
        state = .booting

        #if os(macOS)
        BootstrapEnvironment.raiseFileDescriptorLimit()
        #endif

        // 磁盘预检必须早于装配：SwiftData 会把 ENOSPC 折叠成无根因的
        // SwiftDataError，只有主动探测才能把「磁盘满」归因出来。
        let dataRoot = manifest.storage.dataRootDirectoryOverride?()
            ?? DefaultStorageProvider.makeDefaultDataRootDirectory()
        let space = BootstrapEnvironment.evaluateSpace(at: dataRoot)
        if case .insufficient(let available, let required) = space {
            let report = BootstrapFailureReport(
                kind: .insufficientDiskSpace(availableBytes: available, requiredBytes: required),
                technicalDetail: "Volume available capacity \(available) bytes is below the required \(required) bytes."
            )
            logger.error("Boot blocked: insufficient disk space")
            state = .failed(report)
            return
        }

        do {
            let kernel = try await KernelAssembler.makeKernel(manifest: manifest)
            state = .ready(kernel)
        } catch {
            let report = BootstrapFailureClassifier.classify(
                context: BootstrapFailureContext(error: error),
                space: space
            )
            logger.error("Boot failed: \(report.technicalDetail, privacy: .public)")
            state = .failed(report)
        }
    }

    /// 失败后重试（重新走完整预检 + 装配）。
    public func retry() async {
        guard case .failed = state else { return }
        await boot()
    }

    /// 停止内核并释放装配期观察者（测试 / 应用退出）。
    public func shutdown() async {
        if let kernel {
            KernelAssembler.releaseHandles(for: kernel)
            try? await kernel.stopAsync()
        }
        state = .idle
    }
}