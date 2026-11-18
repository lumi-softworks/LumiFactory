import SwiftUI
import XCTest
@testable import LumiFactory

/// 加载页品牌叠加层挂点：宿主的标记必须真的渲染在进度环之上。
@MainActor
final class LoadingBrandTests: XCTestCase {
    #if os(macOS)
    func testBrandOverlayRendersAboveProgressRing() throws {
        let overlay = AnyView(
            Circle()
                .fill(Color(red: 1, green: 0, blue: 1))
                .frame(width: 104, height: 104)
        )

        let withOverlay = try render(HostLoadingBrandView(overlay: overlay))
        let withoutOverlay = try render(HostLoadingBrandView(overlay: nil))

        XCTAssertGreaterThan(magentaPixelCount(in: withOverlay), 0)
        XCTAssertEqual(magentaPixelCount(in: withoutOverlay), 0)
    }

    func testManifestKeepsLoadingBrandOverlayHook() throws {
        var manifest = makeManifest(dataRoot: makeTemporaryDirectory())
        XCTAssertNil(manifest.makeLoadingBrandOverlay)

        manifest.makeLoadingBrandOverlay = {
            AnyView(Circle().frame(width: 10, height: 10))
        }
        let view = try XCTUnwrap(manifest.makeLoadingBrandOverlay?())
        XCTAssertNotNil(view)
    }

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: 190, height: 190))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func magentaPixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] > 200, pixels[index + 1] < 80, pixels[index + 2] > 200 {
                count += 1
            }
        }
        return count
    }
    #endif
}