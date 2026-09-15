import XCTest
import IMCallEngine
@testable import IMCallKit

/**
 IMCallKit 的 ObjC 支持（2026-09-15）：只读状态查询是不是转发到了 `state` 里的对应字段、
 `IMCallKitPhase` 与 `IMCallPhase` 是不是一一对应、ObjC 可用的状态观察者是不是真的收到通知
 （且移除后不再收到）。**不需要网络**：与 `InviteMemberProviderTests` 同一个套路，
 `IMCallController` 内部靠 `apply(_:)` 驱动状态（module-internal）。
 */
final class ObjCBridgeTests: XCTestCase {

    private func makeController() -> IMCallController {
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: nil)
        return IMCallController(engine: engine)
    }

    // MARK: - IMCallKitPhase 镜像

    /// `objcPhase` 逐一对应 `IMCallPhase`，顺序、含义都不能错——ObjC 宿主拿到的是 `Int`，
    /// 排错全靠这张表还原，值一旦串位就是「明明在响铃却显示已挂断」这种事故。
    func testObjCPhaseMirrorsCallPhaseForEveryCase() {
        let controller = makeController()

        controller.apply(.callReceived(callID: "c", caller: "alice", calleeIDs: [],
                                       mediaType: "audio", isGroup: false))
        XCTAssertEqual(controller.state.phase, .incoming)
        XCTAssertEqual(controller.objcPhase, .incoming)

        controller.apply(.dismiss)
        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        XCTAssertEqual(controller.state.phase, .outgoing)
        XCTAssertEqual(controller.objcPhase, .outgoing)

        controller.apply(.callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                    isGroup: false, role: "caller", now: 1))
        XCTAssertEqual(controller.state.phase, .connecting)
        XCTAssertEqual(controller.objcPhase, .connecting)

        controller.apply(.mediaReady)
        XCTAssertEqual(controller.state.phase, .active)
        XCTAssertEqual(controller.objcPhase, .active)

        controller.apply(.callEnd(reason: "hangup", durationSec: 12))
        XCTAssertEqual(controller.state.phase, .ended)
        XCTAssertEqual(controller.objcPhase, .ended)

        controller.apply(.dismiss)
        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertEqual(controller.objcPhase, .idle)
    }

    // MARK: - 只读查询转发到 state

    func testReadOnlyQueriesReflectState() {
        let controller = makeController()
        controller.apply(.callReceived(callID: "call-9", caller: "alice", calleeIDs: ["dave"],
                                       mediaType: "video", isGroup: true))

        XCTAssertTrue(controller.isGroupCall)
        XCTAssertEqual(controller.currentCallID, "call-9")
        XCTAssertEqual(controller.currentMediaType, "video")
        XCTAssertEqual(controller.peerUID, "", "群通话没有单一对端，peerUID 为空")
        XCTAssertFalse(controller.isMinimized)

        controller.apply(.setMinimized(true))
        XCTAssertTrue(controller.isMinimized)
    }

    /// 1v1 时 `peerUID` 有值，群通话时为空——与 `IMCallViewState.peerUID` 的既有语义一致。
    func testPeerUIDOnlySetForOneOnOne() {
        let controller = makeController()
        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        XCTAssertEqual(controller.peerUID, "bob")
        XCTAssertFalse(controller.isGroupCall)
    }

    // MARK: - ObjC 状态观察者

    private final class RecordingObjCObserver: NSObject, IMCallControllerStateObserver {
        var updateCount = 0
        var lastPhase: IMCallKitPhase?
        func callControllerDidUpdateState(_ controller: IMCallController) {
            updateCount += 1
            lastPhase = controller.objcPhase
        }
    }

    func testStateObserverReceivesUpdates() {
        let controller = makeController()
        let observer = RecordingObjCObserver()
        controller.addStateObserver(observer)

        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))

        XCTAssertGreaterThanOrEqual(observer.updateCount, 1)
        XCTAssertEqual(observer.lastPhase, .outgoing)
    }

    /// 移除之后不该再收到广播——`objcObservers` 与 Swift-only 的 `observers` 是两张独立的表，
    /// 移除一个不该影响另一个，也不该在移除后继续持有强引用式的通知。
    func testRemovedStateObserverStopsReceivingUpdates() {
        let controller = makeController()
        let observer = RecordingObjCObserver()
        controller.addStateObserver(observer)
        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        let countAfterFirst = observer.updateCount
        XCTAssertGreaterThan(countAfterFirst, 0)

        controller.removeStateObserver(observer)
        controller.apply(.dismiss)

        XCTAssertEqual(observer.updateCount, countAfterFirst, "移除之后不该再收到通知")
    }

    /// Swift-only 的 `IMCallControllerObserver` 与 ObjC 的 `IMCallControllerStateObserver`
    /// 互不干扰：两边各自登记、各自收到自己那份广播。
    private final class RecordingSwiftObserver: IMCallControllerObserver {
        var updateCount = 0
        func callController(_ controller: IMCallController, didChange state: IMCallViewState) {
            updateCount += 1
        }
    }

    func testSwiftAndObjCObserversBothFire() {
        let controller = makeController()
        let swiftObserver = RecordingSwiftObserver()
        let objcObserver = RecordingObjCObserver()
        controller.addObserver(swiftObserver)
        controller.addStateObserver(objcObserver)

        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))

        XCTAssertGreaterThan(swiftObserver.updateCount, 0)
        XCTAssertGreaterThan(objcObserver.updateCount, 0)
    }

    // MARK: - Kit 版本号 ObjC 可读

    func testKitVersionMatchesEngineVersion() {
        XCTAssertEqual(IMCallKit.kitVersion, IMCallKitVersion)
        XCTAssertEqual(IMCallKit.kitVersion, IMCallEngineVersion, "五端共享大版本，不单独维护")
    }
}
