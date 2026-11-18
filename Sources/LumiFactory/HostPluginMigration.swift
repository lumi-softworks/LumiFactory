import Foundation
import KernelCore
import OSLog
import ProviderStorage

/// 插件数据迁移的统一时序（对齐 Lumi `PluginDataMigrationCoordinator` 语义）。
///
/// 两条规则：
/// 1. **逐插件隔离**：单个插件迁移失败只记日志，不阻断其余插件与启动——
///    迁移是尽力而为的数据保全，不是启动的前置条件。
/// 2. **旧目录保留不动**：复制而非移动，回滚旧版本仍可读。
@MainActor
enum HostPluginMigration {
    /// Provider 创建前的基础设施目录迁移（启用状态、主题选择等装配期就要读的数据）。
    static func migrateInfrastructure(
        storage: any StorageProviding,
        migrations: [String: [String]],
        logger: Logger
    ) {
        for (pluginID, legacyNames) in migrations.sorted(by: { $0.key < $1.key }) {
            do {
                try StorageDataMigration.migrate(
                    storage: storage,
                    pluginID: pluginID,
                    legacyDirectoryNames: legacyNames
                )
            } catch {
                logger.error("Infrastructure migration failed for \(pluginID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 插件级迁移：在插件 boot 之前逐个执行，失败隔离。
    static func migratePlugins(
        _ plugins: [any SuperPlugin],
        storage: any StorageProviding,
        logger: Logger
    ) {
        let runner = PluginDataMigrationRunner(storage: storage)
        for plugin in plugins {
            do {
                try runner.run(for: [plugin])
            } catch {
                logger.error("Plugin data migration failed for \(plugin.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}