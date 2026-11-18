import KernelCore
import ProviderLogo
import ProviderPluginManaging
import ProviderRootView
import ProviderSettingView
import ProviderStorage
import ProviderTheme
import ProviderToast
import SwiftUI
import XCTest
@testable import LumiFactory

@MainActor
final class KernelBootstrapperTests: XCTestCase {
    private var dataRoot: URL!

    override func setUp() async throws {
        dataRoot = makeTemporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataRoot)
        dataRoot = nil
    }

    func testBootRegistersBaselineProviders() async throws {
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot))
        await bootstrapper.boot()

        guard case .ready(let kernel) = bootstrapper.state else {
            return XCTFail("Expected ready, got \(bootstrapper.state)")
        }
        XCTAssertNotNil(kernel.resolveProvider((any RootViewProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any SettingViewProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any ProviderTheme.ThemeProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any ToastProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any PluginManaging).self))
        XCTAssertNotNil(kernel.resolveProvider(LogoProviding.self))
        let storage = kernel.resolveProvider((any StorageProviding).self)
        XCTAssertEqual(storage?.dataRootDirectory.standardizedFileURL, dataRoot.standardizedFileURL)
        XCTAssertNotNil(kernel.stateStore)
    }

    func testBootIsIdempotent() async throws {
        let plugin = FakePlugin(id: "test.once")
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot) { [plugin] })
        await bootstrapper.boot()
        let firstKernel = bootstrapper.kernel
        await bootstrapper.boot()

        XCTAssertNotNil(firstKernel)
        XCTAssertTrue(bootstrapper.kernel === firstKernel)
        XCTAssertEqual(plugin.bootCount, 1)
    }

    func testPluginFilterExcludesPlugins() async throws {
        let included = FakePlugin(id: "test.included")
        let excluded = FakePlugin(id: "test.excluded")
        let manifest = makeManifest(
            dataRoot: dataRoot,
            plugins: { [included, excluded] },
            pluginFilter: { $0.id != "test.excluded" }
        )
        let bootstrapper = KernelBootstrapper(manifest: manifest)
        await bootstrapper.boot()

        XCTAssertNotNil(bootstrapper.kernel)
        XCTAssertEqual(included.bootCount, 1)
        XCTAssertEqual(excluded.bootCount, 0)
    }

    func testLegacyAliasesConfiguredBeforeBoot() async throws {
        let aliases = ["test.new": "test.old"]
        let plugin = FakePlugin(id: "test.new")
        var seenAliases: [String: String] = [:]
        plugin.bootHandler = { kernel in
            seenAliases = kernel.legacyPluginIDAliases
        }
        let manifest = makeManifest(
            dataRoot: dataRoot,
            plugins: { [plugin] },
            legacyPluginIDAliases: aliases
        )
        await KernelBootstrapper(manifest: manifest).boot()

        XCTAssertEqual(seenAliases, aliases)
    }

    func testSettingsSelectionResetToLowestOrder() async throws {
        // 先注册的插件 order 大、后注册的 order 小：首个 addEntries 会把选中态
        // 锁定为当时的唯一入口，装配完成后必须重置到 order 最小的入口。
        let first = FakePlugin(id: "test.first", order: 100)
        first.bootHandler = { kernel in
            kernel.resolveProvider((any SettingViewProviding).self)?.addEntries([
                SettingEntryItem(id: "a", title: "A", systemImage: "a.circle", order: 10) { Text("A") }
            ])
        }
        let second = FakePlugin(id: "test.second", order: 200)
        second.bootHandler = { kernel in
            kernel.resolveProvider((any SettingViewProviding).self)?.addEntries([
                SettingEntryItem(id: "b", title: "B", systemImage: "b.circle", order: 5) { Text("B") }
            ])
        }
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot) { [first, second] })
        await bootstrapper.boot()

        let settings = bootstrapper.kernel?.resolveProvider((any SettingViewProviding).self)
        XCTAssertEqual(settings?.selectedEntryID, "b")
    }

    func testPluginBootFailureProducesAttributedReport() async throws {
        let plugin = FakePlugin(id: "test.failing")
        plugin.bootHandler = { _ in throw TestError.boom }
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot) { [plugin] })
        await bootstrapper.boot()

        guard case .failed(let report) = bootstrapper.state else {
            return XCTFail("Expected failed, got \(bootstrapper.state)")
        }
        XCTAssertEqual(report.kind, .pluginBootFailed)
        XCTAssertEqual(report.pluginID, "test.failing")
        XCTAssertNotNil(report.phase)
        XCTAssertTrue(report.technicalDetail.contains("boom"))
        XCTAssertNil(bootstrapper.kernel)
    }

    func testRetryAfterFailureReboots() async throws {
        var shouldFail = true
        let plugin = FakePlugin(id: "test.flaky")
        plugin.bootHandler = { _ in
            if shouldFail { throw TestError.boom }
        }
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot) { [plugin] })
        await bootstrapper.boot()
        guard case .failed = bootstrapper.state else {
            return XCTFail("Expected failed on first boot")
        }

        shouldFail = false
        await bootstrapper.retry()
        XCTAssertNotNil(bootstrapper.kernel)
        XCTAssertEqual(plugin.bootCount, 2)
    }

    func testRetryIsNoOpWhenNotFailed() async throws {
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot))
        await bootstrapper.boot()
        let kernel = bootstrapper.kernel
        await bootstrapper.retry()
        XCTAssertTrue(bootstrapper.kernel === kernel)
    }

    func testInsufficientDiskSpaceBlocksBoot() async throws {
        setenv("LUMI_MIN_FREE_DISK_BYTES", "999999999999999", 1)
        defer { unsetenv("LUMI_MIN_FREE_DISK_BYTES") }

        let plugin = FakePlugin(id: "test.never-boots")
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot) { [plugin] })
        await bootstrapper.boot()

        guard case .failed(let report) = bootstrapper.state else {
            return XCTFail("Expected failed, got \(bootstrapper.state)")
        }
        guard case .insufficientDiskSpace = report.kind else {
            return XCTFail("Expected insufficientDiskSpace, got \(report.kind)")
        }
        XCTAssertEqual(plugin.bootCount, 0)
    }

    func testShutdownReleasesKernel() async throws {
        let bootstrapper = KernelBootstrapper(manifest: makeManifest(dataRoot: dataRoot))
        await bootstrapper.boot()
        XCTAssertNotNil(bootstrapper.kernel)

        await bootstrapper.shutdown()
        XCTAssertNil(bootstrapper.kernel)
        guard case .idle = bootstrapper.state else {
            return XCTFail("Expected idle after shutdown")
        }
    }

    func testInfrastructureMigrationCopiesAndPreservesLegacy() async throws {
        // 数据根必须是版本化命名，迁移才能发现兄弟版本根。
        let parent = dataRoot!
        let currentRoot = parent.appendingPathComponent("db_production_v6", isDirectory: true)
        let legacyRoot = parent.appendingPathComponent("db_production_v5", isDirectory: true)
        let legacyPluginDir = legacyRoot.appendingPathComponent("legacy-name", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPluginDir, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: legacyPluginDir.appendingPathComponent("marker.txt"))

        let manifest = makeManifest(
            dataRoot: currentRoot,
            legacyDirectoryMigrations: ["test.plugin": ["legacy-name"]]
        )
        let bootstrapper = KernelBootstrapper(manifest: manifest)
        await bootstrapper.boot()
        XCTAssertNotNil(bootstrapper.kernel)

        let storage = bootstrapper.kernel?.resolveProvider((any StorageProviding).self)
        let migrated = storage?.pluginDataDirectory(for: "test.plugin")
            .appendingPathComponent("marker.txt")
        XCTAssertEqual(try Data(contentsOf: migrated!), Data("payload".utf8))
        // 旧目录保留不动：回滚旧版本仍可读。
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPluginDir.appendingPathComponent("marker.txt").path))
    }
}