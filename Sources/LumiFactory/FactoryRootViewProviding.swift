import LumiUI
import PluginRootView
import ProviderRootView
import SwiftUI

/// 兄弟 App 共享的默认根视图：顶部工具栏 +（ActivityBar 竖栏 | 内容区）。
///
/// 在共享 `ConfigurableRootViewProviding`（工具栏 + 内容区）之上补齐
/// ActivityBar 区域，对齐 Lumi 桌面工作台：竖栏位于工具栏下方、内容区左侧，
/// 红绿灯仍悬浮在工具栏上。布局开关与空态文案由 `RootViewLayoutConfiguration`
/// 声明，宿主无需再复制一份专属视图代码。
@MainActor
open class FactoryRootViewProviding: ConfigurableRootViewProviding {
    open override func makeRootView() -> AnyView {
        AnyView(FactoryRootHostView(provider: self, layout: layout))
    }
}

@MainActor
private struct FactoryRootHostView: View {
    @ObservedObject var provider: FactoryRootViewProviding
    let layout: RootViewLayoutConfiguration
    @LumiTheme private var theme

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if layout.showsToolbar,
               RootContentComposer.shouldRenderToolbar(for: provider),
               let toolbarView = provider.toolbarView {
                toolbarView
                AppDivider(.horizontal)
            }
            #endif

            HStack(spacing: 0) {
                if !provider.isRegionHidden(.activityBar),
                   let activityBarView = provider.view(for: .activityBar) {
                    activityBarView
                        // 对齐 Lumi 的 ActivityBar：右侧 1pt 主题分隔线。
                        // 共享包 `borderTrailing()` 画的是 0.5pt 细线，在浅色主题下
                        // 只占半个像素、几乎不可见，因此这里显式补一条 1pt 的线。
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(theme.divider)
                                .frame(width: 1)
                        }
                }

                RootContentComposer.makeRootContent(
                    for: provider,
                    emptyStateTitle: layout.emptyStateTitle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}