import KernelCore
import WorkbenchRootView
import ProviderRootView
import SwiftUI
import XCTest
@testable import LumiFactory

/// 共享默认壳的守卫：根视图布局配置与状态栏默认菜单契约。
@MainActor
final class FactoryShellTests: XCTestCase {
    private var dataRoot: URL!

    override func setUp() async throws {
        dataRoot = makeTemporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataRoot)
        dataRoot = nil
    }

    #if os(macOS)
    func testDefaultRootProviderUsesManifestLayout() async throws {
        var manifest = makeManifest(dataRoot: dataRoot)
        manifest.rootViewLayout = RootViewLayoutConfiguration(
            showsToolbar: true,
            emptyStateTitle: "Empty"
        )
        let kernel = try await KernelAssembler.makeKernel(manifest: manifest)

        let provider = try XCTUnwrap(kernel.resolveProvider((any RootViewProviding).self))
        let factory = try XCTUnwrap(provider as? FactoryRootViewProviding)
        XCTAssertEqual(factory.layout, manifest.rootViewLayout)
    }

    func testCustomRootProviderHookWins() async throws {
        var manifest = makeManifest(dataRoot: dataRoot)
        manifest.makeRootViewProvider = { DefaultRootViewProviding() }
        let kernel = try await KernelAssembler.makeKernel(manifest: manifest)

        let provider = try XCTUnwrap(kernel.resolveProvider((any RootViewProviding).self))
        XCTAssertFalse(provider is FactoryRootViewProviding)
    }

    func testAccessibilityFeatureDefaults() {
        let features = HostFeatures()
        XCTAssertTrue(features.appliesWindowContentIdentifiers)
        XCTAssertFalse(features.usesReadyMarkerOverlays)
        XCTAssertFalse(features.skipsSharedRootViewWiring)
    }

    func testSkippedSharedRootWiringLeavesRegionsUntouched() async throws {
        var manifest = makeManifest(dataRoot: dataRoot)
        manifest.features.skipsSharedRootViewWiring = true
        let kernel = try await KernelAssembler.makeKernel(manifest: manifest)

        let root = try XCTUnwrap(kernel.resolveProvider((any RootViewProviding).self))
        XCTAssertNil(root.toolbarView)
        XCTAssertNil(root.activityBarView)
        XCTAssertNil(root.contentView)
    }

    func testAssemblerBootsInReadyMarkerOverlayMode() async throws {
        var manifest = makeManifest(dataRoot: dataRoot)
        manifest.features.appliesWindowContentIdentifiers = false
        manifest.features.usesReadyMarkerOverlays = true
        let kernel = try await KernelAssembler.makeKernel(manifest: manifest)

        let root = try XCTUnwrap(kernel.resolveProvider((any RootViewProviding).self))
        XCTAssertNotNil(root.contentView)
        _ = HostViewAssembly.settings(kernel: kernel, manifest: manifest)
    }

    func testDefaultMenuItemsContract() {
        let identity = HostIdentity(
            appName: "TestApp",
            loggerSubsystem: "com.coffic.lumi.factory.tests",
            mainWindowID: "test.main",
            settingsWindowID: "test.settings",
            accessibilityPrefix: "test"
        )
        let items = HostStatusBarConfiguration.defaultMenuItems(identity: identity)

        XCTAssertEqual(items.map(\.accessibilityIdentifier), [
            "test.statusbar.main",
            "test.statusbar.settings",
            "test.statusbar.quit",
        ])
        XCTAssertEqual(items[0].title, "TestApp")
        XCTAssertEqual(items[0].windowID, "test.main")
        XCTAssertEqual(items[1].windowID, "test.settings")
        XCTAssertFalse(items[1].title.isEmpty)
        XCTAssertTrue(items[2].isDestructive)
        XCTAssertNotNil(items[2].action)
    }
    #endif
}