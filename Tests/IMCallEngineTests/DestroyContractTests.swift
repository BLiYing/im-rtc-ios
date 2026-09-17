import XCTest
@testable import IMCallEngine

/**
 `destroy()` 之后**每一个**公开方法归哪一类，逐条钉住（`IMCallEngine+Lifecycle.swift` 的文档注释）。

 - 发起类与本地设备类：throw `2005 invalid_state`——与平时失败同一个出口（结果回给调用方）。
 - 提示类与清理类：照常返回、不 throw、不做事——宿主卸载时无脑清理，不该因先后顺序报错。

 归类规则四端共用（server `docs/design/ACTION_RESULT_DESIGN.md` §3 与 R6）；Web 对应
 `packages/call-engine/test/destroyContract.test.ts`。Swift 没法像 Web 那样扫原型，
 **新增公开方法时记得把它补进下面的表**。
 */
final class DestroyContractTests: XCTestCase {

    /// 记下媒体层被碰了什么：清理类在销毁后不该再建视图。
    final class RecordingMedia: IMMediaAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return log }
        private func note(_ what: String) { lock.lock(); log.append(what); lock.unlock() }

        func open(_ events: IMMediaAdapterEvents) {}
        func acquireMicrophone() async throws -> IMLocalTrackInfo {
            note("acquireMic"); return IMLocalTrackInfo(cid: "mic-1", kind: "audio", source: "microphone")
        }
        func probeMicrophone() async throws { note("probeMic") }
        func startLocalPreview() async throws -> IMLocalTrackInfo {
            note("preview"); return IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
            note("acquireCam"); return IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func createPubOffer() async throws -> String { "" }
        func restartPubICE() {}
        func applyPubAnswer(_ sdp: String) async throws {}
        func answerSubOffer(_ sdp: String) async throws -> String { "" }
        func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws {}
        func setMuted(_ cid: String, _ muted: Bool) { note("setMuted") }
        func setSpeakerOn(_ on: Bool) { note("speaker") }
        func switchCamera() async { note("switchCamera") }
        func claimRemoteTracks(_ owners: [String: String]) {}
        func attachRemoteView(_ uid: String, _ view: AnyObject?) { note("attachRemote(\(view == nil ? "nil" : "view"))") }
        func attachLocalView(_ cid: String, _ view: AnyObject?) { note("attachLocal(\(view == nil ? "nil" : "view"))") }
        func close() {}
    }

    private final class Delegate: NSObject, IMCallEngineDelegate {}

    private func destroyed() async -> (IMCallEngine, RecordingMedia) {
        let media = RecordingMedia()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: media)
        await engine.destroy()
        return (engine, media)
    }

    /// 发起类与本地设备类。
    private let throwing: [(String, (IMCallEngine) async throws -> Void)] = [
        ("login", { try await $0.login("token") }),
        ("call(isGroup:)", { _ = try await $0.call(["bob"], mediaType: "video") }),
        ("call(options:)", { _ = try await $0.call(["bob"], mediaType: "video", options: IMCallOptions()) }),
        ("joinCall", { try await $0.joinCall("c-1") }),
        ("accept", { try await $0.accept() }),
        ("reject", { try await $0.reject() }),
        ("cancel", { try await $0.cancel() }),
        ("hangup", { try await $0.hangup() }),
        ("inviteMore", { try await $0.inviteMore(["carol"]) }),
        ("joinRoom", { try await $0.joinRoom("r-1", roomToken: "rt") }),
        ("leaveRoom", { try await $0.leaveRoom() }),
        ("publishMicrophone", { _ = try await $0.publishMicrophone() }),
        ("publishCamera", { _ = try await $0.publishCamera() }),
        ("openMicrophone", { try await $0.openMicrophone() }),
        ("openCamera", { try await $0.openCamera() }),
        ("setMuted", { try await $0.setMuted("mic-1", muted: true) }),
        ("probeMicrophone", { try await $0.probeMicrophone() }),
        ("startLocalPreview", { _ = try await $0.startLocalPreview() }),
        ("switchCamera", { try await $0.switchCamera() }),
    ]

    func testInitiatingMethodsThrow2005AfterDestroy() async {
        for (name, call) in throwing {
            let (engine, media) = await destroyed()
            do {
                try await call(engine)
                XCTFail("\(name)：destroy 之后应当 throw 2005")
            } catch let error as IMRTCError {
                XCTAssertEqual(error.code, .invalidState, name)
            } catch {
                XCTFail("\(name)：应当 throw IMRTCError，实际 \(error)")
            }
            XCTAssertEqual(media.calls(), [], "\(name)：destroy 之后不许再碰媒体层")
        }
    }

    func testHintAndCleanupMethodsAreSilentNoOpsAfterDestroy() async {
        let (engine, media) = await destroyed()
        await engine.setRemoteLayer("bob", layer: "l")
        engine.setSpeakerOn(true)
        engine.updateToken("t2")
        engine.updateToken("t2", expiresAtMS: 1)
        await engine.logout()
        await engine.destroy()
        engine.forceEnd()
        await engine.closeMicrophone()
        await engine.closeCamera()
        engine.stopLocalPreview()
        let view = NSObject()
        engine.attachView("bob", to: view)
        engine.attachLocalView("cam-1", to: view)
        let token = engine.addEventObserver { _ in }
        engine.removeEventObserver(token)
        _ = engine.uid
        _ = await engine.state

        XCTAssertFalse(media.calls().contains("speaker"), "提示类销毁后不做事")
        XCTAssertFalse(media.calls().contains("attachRemote(view)"), "销毁后不再新建渲染视图")
        XCTAssertFalse(media.calls().contains("attachLocal(view)"), "销毁后不再新建渲染视图")
    }

    func testDelegateAndObserversCannotBeReattachedAfterDestroy() async throws {
        let (engine, _) = await destroyed()
        let delegate = Delegate()
        engine.delegate = delegate
        XCTAssertNil(engine.delegate, "destroy 之后挂 delegate 要被拦掉")

        let seen = NSMutableArray()
        engine.addEventObserver { seen.add($0) }
        engine.dispatcher.emit(IMEmittedEvent("onRoomLeft", ["room_id": .string("r-1")]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.count, 0, "destroy 之后 addEventObserver 不再登记")
    }
}
