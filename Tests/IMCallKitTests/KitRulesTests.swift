import XCTest
@testable import IMCallKit
import IMCallEngine

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

/// 悬浮球贴边算术：从 `IMFloatingBubble.snapToEdge(in:)` 下沉出来的纯函数
/// （`Layout/IMFloatingBubbleLayout.swift`）。数按原先内联算法手算：容器 400×800，
/// 悬浮球（含挂断）56×88，离边缘 8pt、离上下 60pt。
final class FloatingBubbleLayoutTests: XCTestCase {
    private let bubble = IMPipSize(width: 56, height: 88)

    func testSnapsToNearerEdge() {
        // 中心在左半边 → 贴左边缘：inset = 200 - 8 - 28 = 164，targetX = 200 - 164 = 36。
        XCTAssertEqual(
            imFloatingBubbleSnapCenter(IMPipPoint(x: 50, y: 400), containerWidth: 400, containerHeight: 800, bubbleSize: bubble),
            IMPipPoint(x: 36, y: 400))
        // 中心在右半边 → 贴右边缘：targetX = 200 + 164 = 364。
        XCTAssertEqual(
            imFloatingBubbleSnapCenter(IMPipPoint(x: 350, y: 400), containerWidth: 400, containerHeight: 800, bubbleSize: bubble),
            IMPipPoint(x: 364, y: 400))
    }

    func testVerticalClampedToInset() {
        // 顶部越界夹到 minY = 44 + 60 = 104。
        XCTAssertEqual(
            imFloatingBubbleSnapCenter(IMPipPoint(x: 50, y: 10), containerWidth: 400, containerHeight: 800, bubbleSize: bubble),
            IMPipPoint(x: 36, y: 104))
        // 底部越界夹到 maxY = 800 - 44 - 60 = 696。
        XCTAssertEqual(
            imFloatingBubbleSnapCenter(IMPipPoint(x: 50, y: 790), containerWidth: 400, containerHeight: 800, bubbleSize: bubble),
            IMPipPoint(x: 36, y: 696))
    }

    func testExactHalfGoesRight() {
        // center.x == half 时 `<` 判假，走右边缘分支——与原实现的分支判据一致。
        XCTAssertEqual(
            imFloatingBubbleSnapCenter(IMPipPoint(x: 200, y: 400), containerWidth: 400, containerHeight: 800, bubbleSize: bubble),
            IMPipPoint(x: 364, y: 400))
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

    /// 接听看的是「来电页上有没有亲手关掉摄像头」，不是 `cameraOn`（交互稿 §01 第 250–252 行）。
    func testDevicesForAnswering() {
        XCTAssertEqual(imPermissionDevicesForAnswering(mediaType: "video", cameraOptedOut: false),
                       [.microphone, .camera], "群通话默认关摄像头，接听也照样问")
        XCTAssertEqual(imPermissionDevicesForAnswering(mediaType: "video", cameraOptedOut: true),
                       [.microphone], "来电页上关掉摄像头再接只要麦克风")
        XCTAssertEqual(imPermissionDevicesForAnswering(mediaType: "audio", cameraOptedOut: false), [.microphone])
    }

    /// 来电页上点开摄像头要看得见自己（2026-09-11 真机），但响铃时不许弹权限框（交互稿 §01）。
    func testPreviewWhileRinging() {
        XCTAssertTrue(imShouldPreviewWhileRinging(mediaType: "video", cameraOn: true, cameraBlocked: false,
                                                  cameraStatus: .granted), "开着 + 早就授权过：起预览")
        XCTAssertFalse(imShouldPreviewWhileRinging(mediaType: "video", cameraOn: true, cameraBlocked: false,
                                                   cameraStatus: .notDetermined), "没问过：响铃时不问，接听时再说")
        XCTAssertFalse(imShouldPreviewWhileRinging(mediaType: "video", cameraOn: true, cameraBlocked: false,
                                                   cameraStatus: .denied))
        XCTAssertFalse(imShouldPreviewWhileRinging(mediaType: "video", cameraOn: false, cameraBlocked: false,
                                                   cameraStatus: .granted), "群通话默认关着：不起")
        XCTAssertFalse(imShouldPreviewWhileRinging(mediaType: "video", cameraOn: true, cameraBlocked: true,
                                                   cameraStatus: .granted))
        XCTAssertFalse(imShouldPreviewWhileRinging(mediaType: "audio", cameraOn: true, cameraBlocked: false,
                                                   cameraStatus: .granted))
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

    func testEveryoneInTheCallSeesTheInviteEntry() {
        XCTAssertTrue(imCanShowInvite(for: groupCall(role: "caller")))
        XCTAssertTrue(imCanShowInvite(for: groupCall(role: "callee")), "通话里的任何人都能加人（2026-09-15 起，原先仅主叫）")
        XCTAssertEqual(imInviteSlotsLeft(for: groupCall(role: "caller")), 7)
    }

    /// 被叫侧记下发起人（选人页靠它认出离场的发起人）；还在响铃时没有入口——那时发了也是 1407。
    func testCalleeRemembersTheCallerAndGetsTheEntryOnceConnected() {
        var state = reduceCallView(IMCallViewState(), .callReceived(callID: "c", caller: "alice", calleeIDs: ["carol"],
                                                                    mediaType: "video", isGroup: true))
        XCTAssertEqual(state.callerUID, "alice")
        XCTAssertFalse(imCanShowInvite(for: state), "还在响铃的人不在通话里")
        state = reduceCallView(state, .callBegin(callID: "c", roomID: "r", mediaType: "video", isGroup: true, role: "callee", now: 1))
        XCTAssertEqual(state.callerUID, "alice", "接通不能把发起人抹掉")
        XCTAssertTrue(imCanShowInvite(for: state))
        XCTAssertEqual(reduceCallView(state, .callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: true)).callerUID, "",
                       "自己拨出的下一通不带上一通的发起人")
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
        // **接通后的 1v1 视频恒为 video 版式**：两边都关摄像头时也不退回语音页，
        // 否则小窗整个消失，用户以为断了，而且再也点不到互换。
        XCTAssertEqual(imPickLayout(for: state), .video, "两端都没画面也留在视频版式")
        XCTAssertEqual(imPickLayout(for: reduceCallView(state, .setCamera(true))), .video)
        XCTAssertEqual(imPickLayout(for: reduceCallView(state, .userVideo(uid: "bob", available: true))), .video)
        XCTAssertEqual(imPickLayout(for: groupCall(role: "caller")), .grid)
        let outgoing = reduceCallView(IMCallViewState(), .callPlaced(calleeIDs: ["bob"], mediaType: "video", isGroup: false))
        XCTAssertEqual(imPickLayout(for: outgoing), .audio, "拨出中是头像页，本端预览另叠一层小窗")
        let audioCall = reduceCallView(IMCallViewState(),
                                       .callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                                  isGroup: false, role: "callee", now: 1))
        XCTAssertEqual(imPickLayout(for: audioCall), .audio, "语音通话恒为语音版式")
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

/// 结束画面的两条：**提示要清掉**、**四端同一张原因表**。
///
/// 提示不清的话，结束画面上写的是刚刚那句「bob 已拒接」而不是结束原因「对方已拒接」——
/// 同一个结局在 iOS 与 Android 上写着不一样的话（真机对比时发现的）。
final class EndedScreenTests: XCTestCase {

    func testEndClearsHint() {
        var state = reduceCallView(IMCallViewState(),
                                   .callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        state = reduceCallView(state, .hint("bob 已拒接"))
        XCTAssertEqual(state.hint, "bob 已拒接")
        state = reduceCallView(state, .callEnd(reason: "reject", durationSec: 0))
        XCTAssertEqual(state.hint, "", "结束时提示要清掉，否则它会顶掉结束原因")
        XCTAssertEqual(state.endReason, "reject")
    }

    /// 时长由服务端给（不变量 I8）。现算的话，没接通的通话 beganAt 是 0，算出来是一九七〇年到现在。
    func testEndCarriesServerDuration() {
        var state = reduceCallView(IMCallViewState(),
                                   .callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        state = reduceCallView(state, .callEnd(reason: "hangup", durationSec: 201))
        XCTAssertEqual(state.endedDurationSec, 201)
        XCTAssertEqual(imEndReasonText("hangup", role: "caller", durationSec: state.endedDurationSec),
                       "通话结束 · 03:21")
    }

    /// 与 Android 的 `endReasonText` / Web 的 `endReasonText` 逐字对齐——漏一条就是两端写着不一样的话。
    func testEveryReasonHasItsOwnSentence() {
        let table: [String: String] = [
            "cancel": "已取消", "reject": "对方已拒接", "busy": "对方忙线中",
            "no_answer": "对方无人接听", "offline": "对方当前不在线", "network": "网络中断",
            "answered_elsewhere": "已在其他设备接听", "rejected_elsewhere": "已在其他设备拒绝",
            "room_closed": "房间已解散", "kicked": "已被移出",
        ]
        for (reason, want) in table {
            XCTAssertEqual(imEndReasonText(reason, role: "caller", durationSec: 0), want, reason)
        }
        XCTAssertEqual(imEndReasonText("什么鬼", role: "caller", durationSec: 0), "已结束",
                       "未知值兜底成「已结束」，不显示原始英文")
    }
}

/// 通话里摄像头起不来要说一句话，不能只把按钮悄悄变灰（server `/guide/kit#hints`）。
final class CameraFailureTests: XCTestCase {

    private func run(_ error: Error) -> IMCallViewState {
        var state = IMCallViewState()
        state = reduceCallView(state, .setCamera(true))
        return imCameraFailureActions(error).reduce(state, reduceCallView)
    }

    func testNoDeviceBlocksAndSaysSo() {
        let state = run(IMRTCError(.deviceNotFound, "没有可用的摄像头"))
        XCTAssertTrue(state.selfState.cameraBlocked)
        XCTAssertFalse(state.selfState.cameraOn)
        XCTAssertEqual(state.hint, "找不到可用的摄像头，已用语音继续通话")
    }

    func testDeniedBlocksAndSaysSo() {
        let state = run(IMRTCError(.devicePermissionDenied, "摄像头权限被拒"))
        XCTAssertTrue(state.selfState.cameraBlocked)
        XCTAssertEqual(state.hint, "没有摄像头权限，已用语音继续通话")
    }

    func testOtherErrorOnlyTurnsButtonOff() {
        let state = run(IMRTCError(.internalError, "boom"))
        XCTAssertFalse(state.selfState.cameraOn, "乐观点亮的按钮要熄掉")
        XCTAssertFalse(state.selfState.cameraBlocked, "不是权限问题，下次还能再点")
        XCTAssertEqual(state.hint, "")
    }
}


/// 扬声器键什么时候该变成路由选择器，以及 Engine 抛来的清单怎么落进 state（设计稿 §04 v3.5）。
final class AudioRoutePickerTests: XCTestCase {

    private func route(_ kind: IMAudioRouteKind, uid: String, name: String = "") -> IMAudioRoute {
        IMAudioRoute(kind: kind, name: name, uid: uid)
    }

    private var builtInTwo: [IMAudioRoute] {
        [route(.earpiece, uid: imAudioRouteEarpieceUID), route(.speaker, uid: imAudioRouteSpeakerUID)]
    }

    func testTwoStateWhenOnlyBuiltIn() {
        XCTAssertFalse(imShowsRoutePicker([]), "空清单 = 不提供路由选择，退回二态开关")
        XCTAssertFalse(imShowsRoutePicker(builtInTwo), "只有内置听筒 / 扬声器：还是二态开关")
    }

    func testPickerWhenThirdRouteAppears() {
        XCTAssertTrue(imShowsRoutePicker(builtInTwo + [route(.bluetooth, uid: "bt-1", name: "AirPods")]))
        XCTAssertTrue(imShowsRoutePicker(builtInTwo + [route(.wiredHeadset, uid: "w-1", name: "有线耳机")]))
    }

    /// 判据是「可选路由的条数」而不是「当前在用的是不是外接设备」——
    /// 用户在面板里选回听筒之后蓝牙还连着，入口不该消失（上一版栽过的跟头）。
    func testPickerStaysWhenCurrentIsBuiltIn() {
        let routes = builtInTwo + [route(.bluetooth, uid: "bt-1", name: "AirPods")]
        var state = IMCallViewState()
        state = reduceCallView(state, .audioRoutesChanged(routes: routes, current: routes[0]))
        XCTAssertTrue(imShowsRoutePicker(state.selfState.audioRoutes),
                      "当前在用听筒，但蓝牙还在清单里：按钮仍是路由选择器")
    }

    func testReducerStoresRoutesAndCurrent() {
        let routes = builtInTwo + [route(.bluetooth, uid: "bt-1", name: "AirPods")]
        var state = IMCallViewState()
        state = reduceCallView(state, .audioRoutesChanged(routes: routes, current: routes.last))
        XCTAssertEqual(state.selfState.audioRoutes.count, 3)
        XCTAssertEqual(state.selfState.currentAudioRoute?.uid, "bt-1")
    }

    /// 勾在扬声器那一行时，老的 `speakerOn` 也要跟着亮——两套意图是同一件事的两种说法。
    func testSpeakerFlagFollowsCurrentRoute() {
        var state = IMCallViewState()
        let routes = builtInTwo + [route(.bluetooth, uid: "bt-1", name: "AirPods")]
        state = reduceCallView(state, .audioRoutesChanged(routes: routes, current: routes[1]))
        XCTAssertTrue(state.selfState.speakerOn, "选中扬声器")
        state = reduceCallView(state, .audioRoutesChanged(routes: routes, current: routes.last))
        XCTAssertFalse(state.selfState.speakerOn, "切到蓝牙就不是外放了")
    }

    func testDisplayNamePrefersDeviceName() {
        XCTAssertEqual(imRouteDisplayName(route(.bluetooth, uid: "bt-1", name: "AirPods Pro")), "AirPods Pro",
                       "外接设备显示系统给的真名")
        XCTAssertEqual(imRouteDisplayName(route(.earpiece, uid: imAudioRouteEarpieceUID)), imT("route.earpiece"),
                       "内置两条没有设备名，用本地化文案")
    }
}
