import XCTest
@testable import IMCallKit

/**
 设计稿 v3 落地的那几条纯逻辑：小窗四角算术、头像哈希、权限三段式、版式选择。
 **全部不需要模拟器**——它们与 Web 端是同一份算法，这里的数就是两端对表用的向量。
 */
final class PipLayoutTests: XCTestCase {

    func testSizeFollowsContainerShape() {
        XCTAssertEqual(imPipSize(containerWidth: 390, containerHeight: 844), IMPipSizePortrait)
        XCTAssertEqual(imPipSize(containerWidth: 1280, containerHeight: 720), IMPipSizeLandscape)
        XCTAssertEqual(imPipSize(containerWidth: 0, containerHeight: 0), IMPipSizeLandscape, "量不到高度按横屏走")
    }

    func testNearestCorner() {
        XCTAssertEqual(imNearestCorner(IMPipPoint(x: 10, y: 10), containerWidth: 400, containerHeight: 800), .topLeft)
        XCTAssertEqual(imNearestCorner(IMPipPoint(x: 390, y: 10), containerWidth: 400, containerHeight: 800), .topRight)
        XCTAssertEqual(imNearestCorner(IMPipPoint(x: 10, y: 790), containerWidth: 400, containerHeight: 800), .bottomLeft)
        XCTAssertEqual(imNearestCorner(IMPipPoint(x: 390, y: 790), containerWidth: 400, containerHeight: 800), .bottomRight)
    }

    /// 与 Web 的 `pip.test.ts` 同一组数。
    func testCornerOriginsAndLift() {
        let size = IMPipSizePortrait
        XCTAssertEqual(imPipOrigin(.topLeft, size: size, containerWidth: 400, containerHeight: 800), IMPipPoint(x: 12, y: 12))
        XCTAssertEqual(imPipOrigin(.topRight, size: size, containerWidth: 400, containerHeight: 800), IMPipPoint(x: 292, y: 12))
        XCTAssertEqual(imPipOrigin(.bottomRight, size: size, containerWidth: 400, containerHeight: 800), IMPipPoint(x: 292, y: 660))
        // 控制条出现 → 上移 88。
        XCTAssertEqual(imPipOrigin(.bottomRight, size: size, containerWidth: 400, containerHeight: 800, lift: 88),
                       IMPipPoint(x: 292, y: 572))
        XCTAssertEqual(imPipOrigin(.bottomRight, size: size, containerWidth: 50, containerHeight: 50), IMPipPoint(x: 0, y: 0),
                       "容器比小窗还小时不出负数")
    }

    func testClamp() {
        let size = IMPipSizePortrait
        XCTAssertEqual(imClampPipOrigin(IMPipPoint(x: -30, y: -30), size: size, containerWidth: 400, containerHeight: 800),
                       IMPipPoint(x: 0, y: 0))
        XCTAssertEqual(imClampPipOrigin(IMPipPoint(x: 999, y: 999), size: size, containerWidth: 400, containerHeight: 800),
                       IMPipPoint(x: 304, y: 672))
    }
}

/// 头像取色：`fnv1a32(uid) % 9`，四端共用。数与 Web 的 `avatar.test.ts` 一致。
final class AvatarTests: XCTestCase {
    func testFNV1a32Vectors() {
        XCTAssertEqual(imFNV1a32(""), 0x811c9dc5)
        XCTAssertEqual(imFNV1a32("a"), 0xe40c292c)
        XCTAssertEqual(imFNV1a32("alice"), 2267157479)
        XCTAssertEqual(imFNV1a32("bob"), 2261164244)
        XCTAssertEqual(imFNV1a32("carol"), 1728614162)
        XCTAssertEqual(imFNV1a32("张三"), 956401659, "非 ASCII 走 UTF-8 字节")
    }

    func testIndexAndInitial() {
        XCTAssertEqual(imAvatarIndex("alice"), Int(2267157479 % 9))
        XCTAssertEqual(imAvatarInitial("bob"), "B")
        XCTAssertEqual(imAvatarInitial("  "), "?")
        XCTAssertEqual(imAvatarInitial("张三"), "张")
    }
}

/// 权限三段式（交互稿 §01–§02）。系统状态、探测、出卡全部注入。
final class PermissionGateTests: XCTestCase {

    private final class FakeProbe: IMDevicePermissionProbe, @unchecked Sendable {
        var statuses: [IMDeviceKind: IMPermissionStatus] = [:]
        func status(of kind: IMDeviceKind) -> IMPermissionStatus { statuses[kind] ?? .granted }
        func request(_ kind: IMDeviceKind) async -> Bool { true }
    }

    private struct Harness {
        let gate: IMPermissionGate
        let cards: Recorder<String>
        let probed: Recorder<IMDeviceKind>
    }

    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
        var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func harness(statuses: [IMDeviceKind: IMPermissionStatus] = [:],
                         answer: Bool = true,
                         failing: [IMDeviceKind: IMPermissionFailure] = [:]) -> Harness {
        let probe = FakeProbe()
        probe.statuses = statuses
        let cards = Recorder<String>()
        let probed = Recorder<IMDeviceKind>()
        let gate = IMPermissionGate(
            systemProbe: probe,
            present: { card in cards.add("\(card.kind):\(card.device.rawValue)"); return answer },
            probe: { kind in
                probed.add(kind)
                if let failure = failing[kind] { throw FakeFailure(failure) }
            },
            classify: { ($0 as? FakeFailure)?.failure })
        return Harness(gate: gate, cards: cards, probed: probed)
    }

    private struct FakeFailure: Error {
        let failure: IMPermissionFailure
        init(_ failure: IMPermissionFailure) { self.failure = failure }
    }

    func testDevicesFor() {
        XCTAssertEqual(imPermissionDevices(mediaType: "audio", withCamera: true), [.microphone])
        XCTAssertEqual(imPermissionDevices(mediaType: "video", withCamera: true), [.microphone, .camera])
        XCTAssertEqual(imPermissionDevices(mediaType: "video", withCamera: false), [.microphone], "关着摄像头接听只要麦克风")
    }

    func testGrantedAsksNothing() async {
        let h = harness(statuses: [.microphone: .granted, .camera: .granted])
        let outcome = await h.gate.ensure([.microphone, .camera])
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(h.cards.all, [], "已授权：一个框都不出")
        XCTAssertEqual(h.probed.all, [.microphone, .camera])
    }

    func testFirstTimeShowsExplanationThenProbes() async {
        let h = harness(statuses: [.microphone: .notDetermined])
        let outcome = await h.gate.ensure([.microphone])
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(h.cards.all, ["explain:microphone"])
        XCTAssertEqual(h.probed.all, [.microphone])
    }

    func testCancelOnExplanationLeavesNoTrace() async {
        let h = harness(statuses: [.microphone: .notDetermined], answer: false)
        let outcome = await h.gate.ensure([.microphone, .camera])
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(h.probed.all, [], "取消就不去碰设备")
    }

    func testMicrophoneDeniedStopsTheCall() async {
        let h = harness(failing: [.microphone: .denied])
        let outcome = await h.gate.ensure([.microphone, .camera])
        XCTAssertEqual(outcome, .micBlocked)
        XCTAssertEqual(h.cards.all, ["blocked:microphone"])
        XCTAssertEqual(h.probed.all, [.microphone], "麦克风被拒就不再问摄像头")
        XCTAssertEqual(imPermissionBlocked(.microphone, .denied).title, "没有麦克风权限，无法通话")
    }

    /// **摄像头被拒不中断通话**：降级为语音继续。
    func testCameraDeniedDegradesToAudio() async {
        let h = harness(failing: [.camera: .denied])
        let outcome = await h.gate.ensure([.microphone, .camera])
        XCTAssertEqual(outcome, .cameraBlocked)
        XCTAssertEqual(h.cards.all, ["blocked:camera"])
        XCTAssertEqual(imPermissionBlocked(.camera, .denied).title, "没有摄像头权限，已用语音继续通话")
    }

    /// 系统说「已拒绝」也要真探一次：判失败靠探测，查询只决定要不要出说明卡。
    func testDeniedStatusStillProbes() async {
        let h = harness(statuses: [.microphone: .denied])
        let outcome = await h.gate.ensure([.microphone])
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(h.cards.all, [])
        XCTAssertEqual(h.probed.all, [.microphone])
    }
}

/// 版式与加人入口的判据（交互稿 §04 / §05）。
final class LayoutRulesTests: XCTestCase {

    private func groupCall(role: String) -> IMCallViewState {
        var state = reduceCallView(IMCallViewState(),
                                   .callBegin(callID: "c", roomID: "r", mediaType: "video", isGroup: true, role: role, now: 1))
        state = reduceCallView(state, .userEnter(uid: "bob"))
        return state
    }

    func testOnlyTheCallerSeesTheInviteEntry() {
        XCTAssertTrue(imCanShowInvite(for: groupCall(role: "caller")))
        XCTAssertFalse(imCanShowInvite(for: groupCall(role: "callee")), "非主叫发 invite_more 会被拒成 1407，入口直接不给")
        XCTAssertEqual(imInviteSlotsLeft(for: groupCall(role: "caller")), 7)
    }

    func testInviteEntryHidesWhenFullOrDenied() {
        var state = groupCall(role: "caller")
        state = reduceCallView(state, .invited(uids: ["c", "d", "e", "f", "g", "h", "i"]))
        XCTAssertEqual(state.participants.count, 8)
        XCTAssertFalse(imCanShowInvite(for: state), "含本端 9 人就满了")
        XCTAssertFalse(imCanShowInvite(for: reduceCallView(groupCall(role: "caller"), .inviteDenied)))
    }

    func testInvitedPlaceholdersAppearImmediatelyAndOnce() {
        var state = groupCall(role: "caller")
        state = reduceCallView(state, .invited(uids: ["dave", "bob"]))
        XCTAssertEqual(state.participants.map(\.uid), ["bob", "dave"], "已在名单里的不重复加")
        XCTAssertFalse(state.participants[1].hasAccepted, "占位格标成响铃中")
    }

    func testMeetingHasNoInviteEntry() {
        XCTAssertFalse(imCanShowInvite(for: reduceCallView(IMCallViewState(), .meetingJoined(roomID: "r", now: 1))))
    }

    func testPickLayout() {
        var state = reduceCallView(IMCallViewState(),
                                   .callBegin(callID: "c", roomID: "r", mediaType: "video", isGroup: false, role: "callee", now: 1))
        state = reduceCallView(state, .userEnter(uid: "bob"))
        XCTAssertEqual(imPickLayout(for: state, hasLocalVideo: false), .audio, "两端都没画面 → 语音版式")
        // callBegin 不动本端开关（那是来电 / 拨出时定的）；开着摄像头且有轨道就够进视频版式。
        XCTAssertEqual(imPickLayout(for: reduceCallView(state, .setCamera(true)), hasLocalVideo: true), .video, "本端有画面就够")
        XCTAssertEqual(imPickLayout(for: state, hasLocalVideo: true), .audio, "摄像头关着，有轨道也不算")
        XCTAssertEqual(imPickLayout(for: reduceCallView(state, .userVideo(uid: "bob", available: true)), hasLocalVideo: false), .video)
        XCTAssertEqual(imPickLayout(for: groupCall(role: "caller"), hasLocalVideo: true), .grid)
        let outgoing = reduceCallView(IMCallViewState(), .callPlaced(calleeIDs: ["bob"], mediaType: "video", isGroup: false))
        XCTAssertEqual(imPickLayout(for: outgoing, hasLocalVideo: true), .audio, "拨出中是头像页，本端预览另叠一层小窗")
    }

    func testSwapAndCameraBlocked() {
        var state = reduceCallView(IMCallViewState(),
                                   .callBegin(callID: "c", roomID: "r", mediaType: "video", isGroup: false, role: "caller", now: 1))
        state = reduceCallView(state, .setSwapped(true))
        XCTAssertTrue(state.isSwapped)
        state = reduceCallView(state, .cameraBlocked)
        XCTAssertTrue(state.selfState.cameraBlocked)
        XCTAssertFalse(state.selfState.cameraOn)
        XCTAssertFalse(reduceCallView(state, .setCamera(true)).selfState.cameraOn, "被拒时开不了")
    }

    /// 提示是**一次性的**：它在 statusLine 里优先于时长，不清的话计时器再也不出现。
    func testHintIsTransient() {
        var state = reduceCallView(IMCallViewState(), .callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                                                 isGroup: true, role: "caller", now: 1))
        state = reduceCallView(state, .hint("通话已满员（最多 9 人）"))
        XCTAssertEqual(state.hint, "通话已满员（最多 9 人）")
        state = reduceCallView(state, .hint(""))
        XCTAssertTrue(state.hint.isEmpty, "撤掉之后标题栏要回到时长")
        XCTAssertEqual(IMHintHoldSeconds, 3)
    }

    /// 加人被服务端拒（1407 / 1202）时，刚摆上去的占位格要收回来——那几个人根本没响过铃。
    func testRevokingAnInviteRemovesOnlyThePlaceholders() {
        var state = groupCall(role: "caller")
        state = reduceCallView(state, .invited(uids: ["dave"]))
        XCTAssertEqual(state.participants.map(\.uid), ["bob", "dave"])

        state = reduceCallView(state, .inviteDenied)
        state = reduceCallView(state, .userRemove(uid: "dave"))
        XCTAssertEqual(state.participants.map(\.uid), ["bob"], "已经在通话里的 bob 不许被连累")
        XCTAssertFalse(state.canInvite)
    }

    func testConnectionBanner() {
        var state = reduceCallView(IMCallViewState(), .connection(.reconnecting))
        XCTAssertEqual(state.connection, .reconnecting)
        // 连接状态跨通话保留：新来电不该把「正在重连」抹掉。
        state = reduceCallView(state, .callReceived(callID: "c", caller: "a", calleeIDs: [], mediaType: "audio", isGroup: false))
        XCTAssertEqual(state.connection, .reconnecting)
        XCTAssertEqual(imNetworkBarsLit(level: 2), 3)
        XCTAssertEqual(imNetworkBarsLit(level: 4), 2)
        XCTAssertEqual(imNetworkBarsLit(level: 6), 1)
        XCTAssertTrue(imIsNetworkPoor(level: 3))
        XCTAssertEqual(imNetworkText(level: 5), "网络很差")
    }
}
