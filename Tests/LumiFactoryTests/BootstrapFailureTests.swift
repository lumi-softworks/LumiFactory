import KernelCore
import XCTest
@testable import LumiFactory

final class BootstrapEnvironmentTests: XCTestCase {
    func testEvaluateVerdicts() {
        XCTAssertEqual(
            BootstrapEnvironment.evaluate(availableBytes: nil),
            .unknown
        )
        XCTAssertEqual(
            BootstrapEnvironment.evaluate(availableBytes: 100, requiredBytes: 50),
            .sufficient
        )
        XCTAssertEqual(
            BootstrapEnvironment.evaluate(availableBytes: 50, requiredBytes: 50),
            .sufficient
        )
        XCTAssertEqual(
            BootstrapEnvironment.evaluate(availableBytes: 49, requiredBytes: 50),
            .insufficient(availableBytes: 49, requiredBytes: 50)
        )
        XCTAssertEqual(
            BootstrapEnvironment.evaluate(availableBytes: 0, requiredBytes: 0),
            .sufficient
        )
    }

    func testAvailableBytesProbesExistingAncestor() throws {
        let parent = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        // 目标目录不存在（全新安装场景）：必须向上找到存在的祖先再探测。
        let missing = parent.appendingPathComponent("not-created-yet/data", isDirectory: true)
        let bytes = BootstrapEnvironment.availableBytes(at: missing)
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 0)
    }

    func testByteFormatIsDeterministic() {
        XCTAssertEqual(BootstrapByteFormat.string(0), "0 MB")
        XCTAssertEqual(BootstrapByteFormat.string(512 * 1024 * 1024), "512 MB")
        XCTAssertEqual(BootstrapByteFormat.string(2 * 1024 * 1024 * 1024), "2 GB")
        XCTAssertEqual(BootstrapByteFormat.string(Int64(1.5 * 1024 * 1024 * 1024)), "1.5 GB")
        XCTAssertEqual(BootstrapByteFormat.string(-5), "0 MB")
    }
}

final class BootstrapFailureTests: XCTestCase {
    func testContextExtractsLifecycleAttribution() {
        let error = KernelCoreError.pluginLifecycleFailed(
            pluginID: "plugin.x",
            phase: "onBoot",
            underlying: TestError.boom
        )
        let context = BootstrapFailureContext(error: error)
        XCTAssertEqual(context.pluginID, "plugin.x")
        XCTAssertEqual(context.phase, "onBoot")
        XCTAssertTrue(context.technicalDetail.contains("boom"))
    }

    func testContextKeepsPlainErrorText() {
        let context = BootstrapFailureContext(error: TestError.boom)
        XCTAssertNil(context.pluginID)
        XCTAssertNil(context.phase)
        XCTAssertTrue(context.technicalDetail.contains("boom"))
    }

    func testDiskInsufficiencyTakesPriorityButKeepsDetail() {
        let context = BootstrapFailureContext(
            pluginID: "plugin.x",
            phase: "onBoot",
            technicalDetail: "SwiftDataError code 1"
        )
        let report = BootstrapFailureClassifier.classify(
            context: context,
            space: .insufficient(availableBytes: 10, requiredBytes: 100)
        )
        XCTAssertEqual(report.kind, .insufficientDiskSpace(availableBytes: 10, requiredBytes: 100))
        XCTAssertEqual(report.pluginID, "plugin.x")
        XCTAssertEqual(report.technicalDetail, "SwiftDataError code 1")
    }

    func testAttributedFailureWithSufficientSpace() {
        let context = BootstrapFailureContext(pluginID: "plugin.x", phase: "onBoot", technicalDetail: "detail")
        let report = BootstrapFailureClassifier.classify(context: context, space: .sufficient)
        XCTAssertEqual(report.kind, .pluginBootFailed)
        XCTAssertEqual(report.pluginID, "plugin.x")
        XCTAssertEqual(report.technicalDetail, "detail")
    }

    func testUnattributedFailureIsUnknown() {
        let context = BootstrapFailureContext(pluginID: nil, phase: nil, technicalDetail: "detail")
        for space in [BootstrapSpaceVerdict.sufficient, .unknown] {
            let report = BootstrapFailureClassifier.classify(context: context, space: space)
            XCTAssertEqual(report.kind, .unknown)
            XCTAssertEqual(report.technicalDetail, "detail")
        }
    }
}

@MainActor
final class HostWindowOpenerTests: XCTestCase {
    func testQueuedRequestsFlushOnCapture() {
        let opener = HostWindowOpener()
        var opened: [String] = []

        opener.openWindow(id: "test.settings")
        opener.openWindow(id: "test.settings") // 去重
        opener.openWindow(id: "test.main")
        XCTAssertTrue(opened.isEmpty)

        opener.capture { id in opened.append(id) }
        XCTAssertEqual(opened, ["test.settings", "test.main"])

        opener.openWindow(id: "test.late")
        XCTAssertEqual(opened, ["test.settings", "test.main", "test.late"])
    }
}