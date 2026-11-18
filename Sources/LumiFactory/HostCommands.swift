#if os(macOS)
import AppKit
import Combine
import KernelCore
import ProviderCommand
import SwiftUI

/// 共享应用命令：⌘, 设置 + `CommandProviding` 契约驱动的插件命令。
///
/// 静态 placement 走 SwiftUI `CommandGroup`；数量动态的独立顶层菜单
/// （`CommandMenu` 无法由 `ForEach` 构建）经 AppKit 轮询安装器挂到主菜单。
///
/// 内核在场景构建之后才异步就绪，因此这里持有 `KernelBootstrapper`：
/// 插件命令在内核就绪后自动出现，安装器轮询期间持续探测 Provider。
///
/// `@Environment(\.openWindow)` 只在独立的 Commands 结构体里有效——
/// 挂在嵌套 App 结构体上只会读到默认值并告警。
public struct HostCommands: Commands {
    private let bootstrapper: KernelBootstrapper

    @Environment(\.openWindow) private var openWindow

    public init(bootstrapper: KernelBootstrapper) {
        self.bootstrapper = bootstrapper
        HostCommandMenuInstaller.shared.start(bootstrapper: bootstrapper)
    }

    public var body: some Commands {
        // Commands 在场景构建期即被求值（早于任何窗口出现，也早于
        // applicationDidFinishLaunching）。在此捕获 openWindow，使 AppDelegate
        // 能在启动时确定性地开窗，不必等首个窗口 onAppear（后台启动时它可能永不出现）。
        let openWindow = self.openWindow
        let _ = HostWindowOpener.shared.capture { id in openWindow(id: id) }

        // Window 场景（而非 Settings 场景）下系统不再自动绑定 Cmd+,，等价补回。
        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Settings...", bundle: .module)) {
                openWindow(id: bootstrapper.manifest.identity.settingsWindowID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            if let checkForUpdates = bootstrapper.manifest.features.checkForUpdates {
                Button(String(localized: "Check for Updates...", bundle: .module)) {
                    checkForUpdates()
                }
            }
            HostPluginCommandContent(bootstrapper: bootstrapper, placement: .appMenu)
        }

        CommandGroup(after: .toolbar) {
            HostPluginCommandContent(bootstrapper: bootstrapper, placement: .toolbar)
        }
    }
}

private struct HostPluginCommandContent: View {
    @ObservedObject private var bootstrapper: KernelBootstrapper
    private let placement: CommandMenuPlacement

    init(bootstrapper: KernelBootstrapper, placement: CommandMenuPlacement) {
        self.bootstrapper = bootstrapper
        self.placement = placement
    }

    var body: some View {
        if let kernel = bootstrapper.kernel {
            HostPluginCommandGroups(kernel: kernel, placement: placement)
                .id(ObjectIdentifier(kernel))
        }
    }
}

private struct HostPluginCommandGroups: View {
    @StateObject private var model: HostCommandGroupsModel

    init(kernel: KernelCoreContainer, placement: CommandMenuPlacement) {
        _model = StateObject(
            wrappedValue: HostCommandGroupsModel(
                provider: kernel.resolveProvider((any CommandProviding).self),
                placement: placement
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.groups) { group in
                ForEach(group.items) { item in
                    Button(item.title) {
                        item.action()
                    }
                    .keyboardShortcut(item.shortcut, modifiers: item.modifiers)
                }
            }
        }
    }
}

@MainActor
private final class HostCommandGroupsModel: ObservableObject {
    @Published private(set) var groups: [CommandMenuGroup]
    private let provider: (any CommandProviding)?
    private let placement: CommandMenuPlacement
    private var observer: (any CommandProvidingObserverHandle)?
    private var lastSignature: String?

    init(provider: (any CommandProviding)?, placement: CommandMenuPlacement) {
        self.provider = provider
        self.placement = placement
        let groups = provider?.allCommandGroups.filter { $0.placement == placement } ?? []
        self.groups = groups
        self.lastSignature = hostCommandGroupsSignature(groups)
        self.observer = provider?.addObserver { [weak self] _ in
            guard let self else { return }
            let groups = self.provider?.allCommandGroups.filter { $0.placement == self.placement } ?? []
            let signature = hostCommandGroupsSignature(groups)
            guard signature != self.lastSignature else { return }
            self.groups = groups
            self.lastSignature = signature
        }
    }
}

/// 顶层菜单的 AppKit 安装器：SwiftUI 替换主菜单实例时重新挂接，
/// 结构变化时重建，仅状态变化时原地更新勾选。
@MainActor
private final class HostCommandMenuInstaller {
    static let shared = HostCommandMenuInstaller()

    private weak var bootstrapper: KernelBootstrapper?
    private weak var commandProvider: (any CommandProviding)?
    private var commandProviderObserver: (any CommandProvidingObserverHandle)?
    private var pollingTask: Task<Void, Never>?
    private var installedMainMenu: NSMenu?
    private var installedMenus: [String: NSMenuItem] = [:]
    private var installedItems: [String: NSMenuItem] = [:]
    private var actionTargets: [String: HostCommandActionTarget] = [:]
    private var lastStructureSignature: String?

    func start(bootstrapper: KernelBootstrapper) {
        self.bootstrapper = bootstrapper
        guard pollingTask == nil else { return }

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.attachProviderIfNeeded()
                self.synchronizeIfPossible()
                if NSApplication.shared.mainMenu == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// 内核就绪后解析 CommandProviding 并订阅变更（只挂一次）。
    private func attachProviderIfNeeded() {
        guard commandProvider == nil,
              let kernel = bootstrapper?.kernel,
              let provider = kernel.resolveProvider((any CommandProviding).self)
        else { return }
        commandProvider = provider
        commandProviderObserver = provider.addObserver { [weak self] _ in
            self?.synchronizeIfPossible()
        }
    }

    private func synchronizeIfPossible() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }

        if installedMainMenu !== mainMenu {
            installedMainMenu = mainMenu
            // SwiftUI 的命令树变化会替换 NSMenu 实例；保留已装菜单项/目标，
            // 下次同步直接挂到新菜单上，不必先从可见菜单移除。
            lastStructureSignature = nil
        }

        let groups = commandProvider?.allCommandGroups
            .filter { $0.placement == .topLevelMenu } ?? []
        let structureSignature = hostCommandGroupsStructureSignature(groups)
        let wasEvicted = installedMenus.values.contains { installed in
            !mainMenu.items.contains { $0 === installed }
        }

        if structureSignature != lastStructureSignature || wasEvicted {
            synchronize(in: mainMenu, groups: groups)
            lastStructureSignature = structureSignature
        } else {
            updateStates(for: groups)
        }
    }

    private func synchronize(in mainMenu: NSMenu, groups: [CommandMenuGroup]) {
        let groupIDs = Set(groups.map(\.id))
        let removedGroups = installedMenus.filter { !groupIDs.contains($0.key) }
        for (groupID, menuItem) in removedGroups {
            if mainMenu.items.contains(where: { $0 === menuItem }) {
                mainMenu.removeItem(menuItem)
            }
            installedMenus.removeValue(forKey: groupID)
            removeInstalledItems(for: groupID)
        }

        for group in groups {
            let rootItem = installedMenus[group.id]
                ?? NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            rootItem.title = group.name
            let submenu = rootItem.submenu ?? NSMenu(title: group.name)
            submenu.title = group.name
            removeInstalledItems(for: group.id)
            submenu.removeAllItems()

            for item in group.items {
                let target = HostCommandActionTarget(action: item.action)
                let child = NSMenuItem(
                    title: item.title,
                    action: #selector(HostCommandActionTarget.performAction(_:)),
                    keyEquivalent: item.shortcut.map(String.init) ?? ""
                )
                child.keyEquivalentModifierMask = item.modifiers.appKitModifiers
                child.state = item.state == .on ? .on : .off
                child.target = target
                submenu.addItem(child)
                let itemKey = installedItemKey(groupID: group.id, itemID: item.id)
                installedItems[itemKey] = child
                actionTargets[itemKey] = target
            }

            rootItem.submenu = submenu
            if !mainMenu.items.contains(where: { $0 === rootItem }) {
                mainMenu.addItem(rootItem)
            }
            installedMenus[group.id] = rootItem
        }

        updateStates(for: groups)
    }

    private func updateStates(for groups: [CommandMenuGroup]) {
        for group in groups {
            for item in group.items {
                let key = installedItemKey(groupID: group.id, itemID: item.id)
                installedItems[key]?.state = item.state == .on ? .on : .off
            }
        }
    }

    private func removeInstalledItems(for groupID: String) {
        let prefix = "\(groupID)."
        installedItems.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { installedItems.removeValue(forKey: $0) }
        actionTargets.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { actionTargets.removeValue(forKey: $0) }
    }

    private func installedItemKey(groupID: String, itemID: String) -> String {
        "\(groupID).\(itemID)"
    }
}

@MainActor
private final class HostCommandActionTarget: NSObject {
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @objc func performAction(_ sender: NSMenuItem) {
        action()
    }
}

@MainActor
private func hostCommandGroupsSignature(_ groups: [CommandMenuGroup]) -> String {
    groups.map { group in
        let items = group.items.map { item in
            "\(item.id)=\(item.title)=\(item.shortcut.map(String.init) ?? "")=\(item.modifiers.rawValue)=\(item.state)"
        }.joined(separator: ";")
        return "\(group.id)=\(group.name)=[\(items)]"
    }.joined(separator: "|")
}

@MainActor
private func hostCommandGroupsStructureSignature(_ groups: [CommandMenuGroup]) -> String {
    groups.map { group in
        let items = group.items.map { item in
            "\(item.id)=\(item.title)=\(item.shortcut.map(String.init) ?? "")=\(item.modifiers.rawValue)"
        }.joined(separator: ";")
        return "\(group.id)=\(group.name)=[\(items)]"
    }.joined(separator: "|")
}

private extension View {
    @ViewBuilder
    func keyboardShortcut(_ key: Character?, modifiers: CommandModifiers) -> some View {
        if let key {
            keyboardShortcut(KeyEquivalent(key), modifiers: modifiers.swiftUIModifiers)
        } else {
            self
        }
    }
}

private extension CommandModifiers {
    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}
#endif