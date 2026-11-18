import Foundation
import KernelCore
import LumiFactory
import SwiftUI

/// 最小可用插件：记录 boot 调用，可注入 boot 行为。
@MainActor
final class FakePlugin: SuperPlugin {
    let id: String
    let metadata: PluginMetadata
    var order: Int
    var bootHandler: (@MainActor (KernelCoreContainer) throws -> Void)?
    private(set) var bootCount = 0

    init(id: String, order: Int = 200) {
        self.id = id
        self.order = order
        self.metadata = PluginMetadata(id: id)
    }

    func onBoot(kernel: KernelCoreContainer) throws {
        bootCount += 1
        try bootHandler?(kernel)
    }
}

enum TestError: Error, Equatable {
    case boom
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumiFactoryTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func makeManifest(
    dataRoot: URL,
    plugins: @escaping @MainActor () -> [any SuperPlugin] = { [] },
    pluginFilter: (@MainActor (any SuperPlugin) -> Bool)? = nil,
    legacyPluginIDAliases: [String: String] = [:],
    legacyDirectoryMigrations: [String: [String]] = [:]
) -> HostManifest {
    HostManifest(
        identity: HostIdentity(
            appName: "TestApp",
            loggerSubsystem: "com.coffic.lumi.factory.tests",
            mainWindowID: "test.main",
            settingsWindowID: "test.settings",
            accessibilityPrefix: "test"
        ),
        makePlugins: plugins,
        pluginFilter: pluginFilter,
        storage: HostStorageConfiguration(
            stateStorePluginID: "test.plugin-manager",
            dataRootDirectoryOverride: { dataRoot },
            legacyDirectoryMigrations: legacyDirectoryMigrations
        ),
        legacyPluginIDAliases: legacyPluginIDAliases
    )
}