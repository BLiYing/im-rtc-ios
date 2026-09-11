#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import UIKit
import WebRTC
import IMCallEngine

/*
 画面挂载与**第一帧检测**。

 # 为什么第一帧要单独检测

 「协商完成」不等于「有画面」。协商完成那一刻远端轨道还是静的，
 UI 如果在那时撤掉 loading，用户看到的是一片黑。

 Web 端为此改过一次：判据从 `ontrack` 改成轨道的 `unmute` 事件，
 实测两者差了 108ms——那 108ms 就是黑屏。iOS 没有 `unmute`，
 等价的做法是挂一个渲染器，**收到第一帧尺寸回调时才算数**。
 */

/// 一次性的第一帧探针。**只报一次**。
///
/// 远端轨道上的那个报完就一直挂着（之后每帧只剩一次加锁判断）；
/// 本端画布用的那个由登记表报完就摘掉（见 `IMVideoRegistry.resetForReopen(owner:)`）。
final class IMFirstFrameProbe: NSObject, RTCVideoRenderer {
    private let onFirstFrame: (_ width: Int32, _ height: Int32, _ rotation: Int) -> Void
    private var fired = false
    /// 还认不认帧。见 ``accept()``。
    private var accepting: Bool
    private let lock = NSLock()

    init(accepting: Bool = true,
         onFirstFrame: @escaping (_ width: Int32, _ height: Int32, _ rotation: Int) -> Void) {
        self.accepting = accepting
        self.onFirstFrame = onFirstFrame
    }

    /**
     accept 从现在起才认帧。

     本端关摄像头时轨道先 `isEnabled = false`，而 `stopCapture` 是排到采集队列上异步停的——
     停下来之前漏过来的那几帧是 libwebrtc 替换出来的**黑帧**。它们不是「重开后的第一帧」，
     拿它们当判据，画布会在用户还没点开摄像头时就先露出来。
     */
    func accept() {
        lock.lock()
        accepting = true
        lock.unlock()
    }

    func setSize(_ size: CGSize) {
        // 尺寸回调也可能先于第一帧到，**不能拿它当判据**——它只说明协商出了分辨率。
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        let fire = accepting && !fired
        if fire { fired = true }
        lock.unlock()
        guard fire else { return }
        onFirstFrame(frame.width, frame.height, frame.rotation.rawValue)
    }
}

/// localViewKey 给本端预览一个不会与 uid 撞车的登记键。
///
/// 本端与远端共用一张登记表（挂载/卸载逻辑一模一样），只需要一个前缀区分开。
/// 前缀带冒号：uid 是宿主给的业务 id，冒号开头的 uid 本来就不该出现在业务里。
/// **与 Web 端同一个写法**（`viewRegistry.ts` 的 `:local:<cid>`）。
func imLocalViewKey(_ cid: String) -> String { ":local:\(cid)" }

/**
 画面挂载表：**轨道按 track_id 收下、按 owner 认领、按 owner 挂载**。

 # 为什么必须有「认领」这一步

 轨道到达与「知道它是谁的」是**两个独立的时序**：`didAdd rtpReceiver` 在
 第一个 RTP 包到达时触发，而 `room.track_published`（带 uid）是信令帧，
 谁先到都可能。

 这里原先直接 `bind(uid: trackID, ...)` —— 把 **track_id 当成了 uid**，
 而挂载那一侧传进来的是真正的 uid，**两把钥匙永远对不上**。
 症状：协商全通、`firstVideoFrame` 照抛、日志一切正常，
 但九宫格里**一格画面都没有**。真机联调时三个人互相看不见就是这个。
 （Web 端一直是对的：`viewRegistry.ts` 有 orphans + claim 两张表。）

 # 为什么整张表只在主线程上动

 表里存的是 `UIView`（`RTCMTLVideoView` 背后是 `CAMetalLayer`）。
 原先用一把 `NSLock` 保护，`attach` 从主线程进、`removeAll` 从 actor 线程进——
 **锁保护得了字典，保护不了 UIKit**。通话结束时在后台线程
 `removeFromSuperview()` 一个正在渲染的 Metal 视图，进程是要挂的。
 改成「主线程独占」之后锁就多余了，也不会再有第二种进入方式。
 */
final class IMVideoRegistry {
    /// owner（uid 或 `:local:cid`）→ 渲染视图。
    private var views: [String: IMAspectVideoView] = [:]
    /// owner → 轨道。
    private var tracks: [String: RTCVideoTrack] = [:]
    /// track_id → 还不知道归属的轨道。
    private var orphans: [String: RTCVideoTrack] = [:]
    /// track_id → owner，认领之后的记账。
    private var owners: [String: String] = [:]
    /// 已经把视图接到轨道上的 owner。见 ``attachRenderer(owner:)``——`add` 不去重。
    private var rendered: Set<String> = []
    /// owner → 本端画布正在等的第一帧。**等到之前画布藏着**（见 ``resetForReopen(owner:)``）。
    private var gates: [String: FirstFrameGate] = [:]
    /// 探针编号。探针在采集线程上报、主线程上认，认的时候可能已经换过一个了——对不上号的作废。
    private var gateSerial = 0

    private struct FirstFrameGate {
        let serial: Int
        let probe: IMFirstFrameProbe
        let track: RTCVideoTrack
        /// 从什么时候开始认帧。nil = 摄像头还关着。
        var openedAt: CFAbsoluteTime?
    }

    /// addTrack 收下一条轨道。`owner` 为空表示「还不知道是谁的」，先进 orphans 等认领。
    func addTrack(_ trackID: String, _ track: RTCVideoTrack, owner: String) {
        onMain { [self] in
            guard !owner.isEmpty else {
                orphans[trackID] = track
                return
            }
            orphans[trackID] = nil
            owners[trackID] = owner
            bind(owner: owner, track: track)
        }
    }

    /// claim 认领一条之前不知道归属的轨道。认领不到（轨道还没来）就什么都不做——
    /// 轨道到达时会走 addTrack 那条路。
    func claim(_ trackID: String, owner: String) {
        onMain { [self] in
            guard !owner.isEmpty, owners[trackID] != owner,
                  let track = orphans[trackID] else { return }
            orphans[trackID] = nil
            owners[trackID] = owner
            bind(owner: owner, track: track)
        }
    }

    /// attach 把某个 owner 的画面挂到宿主给的视图上；传 nil 只从容器上摘下来。
    ///
    /// **重复调用是幂等的**。原先每调一次就 `addSubview` 一个新的
    /// `RTCMTLVideoView`——而 Kit 每次状态变化都会重挂一遍，于是格子里
    /// 叠了一摞渲染视图，只有最下面那张接着轨道。
    ///
    /// # 传 nil 不再拆视图、不再拆 sink
    ///
    /// 本端摄像头关闭时 Kit 会用 `attach(owner:to: nil)` 把预览从容器上收回。
    /// 视图和它接在轨道上的 sink 都**留在表里**——只是暂时没有 superview，
    /// 轨道那边（`RTCCameraVideoCapturer`）也已经停采集，不会再送帧过来。
    /// 整通电话只彻底释放一次，在 `remove`/`removeAll`（挂断、进房前的
    /// `stopLocalPreview`）——见那两个方法的注释。
    /// 与 Android `IMCallKit.localPreviewView` 同一个思路：Kit 层的预览视图
    /// 整通电话只创建一次、反复复用（参见 `im-rtc-android` 的
    /// `IMCallKit.kt` `localPreviewView(context)`）。
    ///
    /// 这个函数本端、远端共用（`owner` 是 uid 或 `imLocalViewKey` 生成的
    /// `:local:<cid>`），所以这条「nil 不拆」的改动对远端 tile 摘视图
    /// （参与者离场）同样生效——效果是好的：对端短暂断线重连时不会因为
    /// 中间那一下 `attach(nil)` 而把已经渲染好的最后一帧连视图一起丢掉，
    /// 与 Android 「九宫格 tile 不传 null 以避免 Surface 销毁闪烁」是同一个方向。
    ///
    /// # 新造的本端画布也等第一帧再露
    ///
    /// 与 Android 渲染器每次 `init` 之后等 `onFirstFrameRendered` 同一个效果，
    /// 顺带在日志里留一行「本端画面首帧到达」和等了多久。
    func attach(owner: String, to container: UIView?) {
        onMain { [self] in
            guard let container else {
                // 只从容器上摘视图，视图与 sink 都留在表里——挂断/通话结束才真释放（见 remove/removeAll）。
                views[owner]?.removeFromSuperview()
                return
            }
            let cached = views[owner]
            let view = cached ?? makeRenderView(owner: owner)
            if view.superview !== container {
                view.removeFromSuperview()
                view.frame = container.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(view)
            }
            views[owner] = view
            attachRenderer(owner: owner)
            guard cached == nil, owner.hasPrefix(imLocalViewKey("")) else { return }
            if gates[owner] == nil {
                armGate(owner: owner, open: true)
            } else {
                view.isHidden = true
            }
        }
    }

    /// remove 摘掉某个 owner 的视图并忘掉它的轨道（进房前关掉的本端预览）。
    /// 只 `attach(owner:to: nil)` 的话轨道还被表攥着，要等通话结束才放。
    func remove(owner: String) {
        onMain { [self] in
            if let view = views[owner] {
                detachRenderer(owner: owner, view: view)
                view.removeFromSuperview()
            }
            dropGate(owner: owner)
            views[owner] = nil
            tracks[owner] = nil
        }
    }

    /// removeAll 清空全部登记（通话结束 / logout）。
    func removeAll() {
        onMain { [self] in
            for (owner, view) in views {
                detachRenderer(owner: owner, view: view)
                view.removeFromSuperview()
            }
            for owner in Array(gates.keys) { dropGate(owner: owner) }
            views = [:]
            tracks = [:]
            orphans = [:]
            owners = [:]
            rendered = []
        }
    }

    /**
     resetForReopen 让某个 owner 的渲染视图「翻篇」：**摄像头关掉的那一刻**调用。
     换上一块藏着的新画布，并挂一个还不认帧的探针；重新打开时 ``awaitFirstFrame(owner:)``
     才开始认帧，第一帧真到了才露出来。

     # 为什么在「关」的时候换，而不是「开」的时候

     原先是开的时候换。可 Kit 在按下按钮的同一拍（主线程、同步）就把格子显出来了，
     而换画布是从 `Task` 里的 `setMuted` 异步回主线程——中间那一两帧露的正是
     关闭前留下的最后一帧，看着就是「先闪一下旧画面，再黑，再出新画面」（2026-09-11 真机）。
     关的时候格子本来就藏着，这时候换，无论 Kit 什么时候把格子显出来，里面都没有旧帧。

     # 为什么是「换一块新画布」而不是「清空这块画布」

     `RTCMTLVideoView` 没有公开的清帧接口——`renderFrame(nil)` 直接 return，不会清空当前
     显示的内容。换一个全新的 `IMAspectVideoView` 实例就不用赌：新视图从没渲染过东西，
     `CAMetalLayer` 天然是空的。与 Android `IMWebRTCAdapter.kt` 的 `attachLocalPreview`
     每次 `release()` + 重新 `init()` 同一个目的：复用的是宿主看到的那个视图**位置**，
     不是画布里已经画上去的像素。

     # 为什么还要等第一帧才露

     Android 的 `SurfaceView` 不可见时 surface 就销毁了，再显出来是空的，第一帧到了才有画面；
     iOS 的 `CAMetalLayer` 会一直留着画过的东西。关摄像头到 `stopCapture` 真停下之间漏过来的
     黑帧也会画到新画布上——所以「新画布」还不够，要藏到**重开之后的第一帧**。

     只对本端调用：调用点是 `IMWebRTCAdapter.setMuted(_:_:)`。远端画面走 `bind` 那条
     「换轨道先摘旧帧」的路，不受影响。
     */
    func resetForReopen(owner: String) {
        onMain { [self] in swapCanvas(owner: owner) }
    }

    /// awaitFirstFrame 摄像头重新打开时调：从这一刻起认帧，第一帧到了才露出画布。
    /// 关的时候没换成（那会儿还没有画布）就现在补换一次。
    func awaitFirstFrame(owner: String) {
        onMain { [self] in
            if gates[owner] == nil { swapCanvas(owner: owner) }
            gates[owner]?.openedAt = CFAbsoluteTimeGetCurrent()
            gates[owner]?.probe.accept()
        }
    }

    // MARK: - 内部（全部在主线程）

    private func swapCanvas(owner: String) {
        guard let old = views[owner] else { return }
        let container = old.superview
        detachRenderer(owner: owner, view: old)
        old.removeFromSuperview()
        let fresh = makeRenderView(owner: owner)
        fresh.inheritVideoSize(from: old)
        if let container {
            fresh.frame = container.bounds
            fresh.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(fresh)
        }
        views[owner] = fresh
        attachRenderer(owner: owner)
        armGate(owner: owner, open: false)
    }

    /// armGate 藏起 owner 的画布，挂一个新探针等第一帧；旧探针（如果有）先摘掉。没有轨道就什么都不做。
    private func armGate(owner: String, open: Bool) {
        guard let track = tracks[owner] else { return }
        dropGate(owner: owner)
        gateSerial += 1
        let serial = gateSerial
        let probe = IMFirstFrameProbe(accepting: open) { [weak self] width, height, rotation in
            let frame = "\(width)x\(height)@\(rotation)"
            DispatchQueue.main.async { self?.firstFrameArrived(owner: owner, serial: serial, frame: frame) }
        }
        gates[owner] = FirstFrameGate(serial: serial, probe: probe, track: track,
                                      openedAt: open ? CFAbsoluteTimeGetCurrent() : nil)
        views[owner]?.isHidden = true
        track.add(probe)
    }

    private func dropGate(owner: String) {
        guard let gate = gates.removeValue(forKey: owner) else { return }
        gate.track.remove(gate.probe)
    }

    private func firstFrameArrived(owner: String, serial: Int, frame: String) {
        guard let gate = gates[owner], gate.serial == serial else { return }
        dropGate(owner: owner)
        views[owner]?.isHidden = false
        let waited = gate.openedAt.map { String(Int((CFAbsoluteTimeGetCurrent() - $0) * 1000)) } ?? "?"
        IMRTCLog.info("本端画面首帧到达", ["owner": owner, "waitMs": waited, "frame": frame])
    }

    private func bind(owner: String, track: RTCVideoTrack) {
        // 同一个 owner 换了轨道（对方关了摄像头再开）：**先把旧轨道从渲染视图上摘掉**，
        // 不摘的话新轨道的帧会和旧轨道的最后一帧抢同一个渲染器，画面停在旧的那一帧。
        if let previous = tracks[owner], previous !== track, let view = views[owner] {
            previous.remove(view)
            rendered.remove(owner)
        }
        tracks[owner] = track
        attachRenderer(owner: owner)
        // 等第一帧的探针还挂在旧轨道上就永远等不到了：跟着换过去，别让画布一直藏着。
        if let gate = gates[owner], gate.track !== track {
            armGate(owner: owner, open: gate.openedAt != nil)
        }
    }

    /**
     attachRenderer 把 owner 的渲染视图接到它的轨道上，**同一对最多接一次**。

     # 为什么必须自己判重

     `RTCVideoTrack.add(_:)` **不去重**：每调一次就新造一个 renderer adapter 挂到
     native 的 sink 列表上。而这条路被调得非常勤——`IMCallOverlayViewController.render`
     每次状态变化都无条件 `attachLocalPreview`，而 `onActiveSpeakers` 每 300ms 就改一次
     音量、状态就变一次，于是一秒好几轮。一通视频打几分钟，同一个 `RTCMTLVideoView`
     上就挂了几百个重复 sink，每一帧渲染几百遍（CPU/GPU 与内存一起涨）；
     而卸载时只 `remove` 一次，多出来的那些**永远回收不掉**。

     `rendered` 记的就是「这个 owner 的视图已经接在它当前那条轨道上了」。
     换轨道（`bind`）与卸载（`detachRenderer`）都会把它划掉。
     */
    private func attachRenderer(owner: String) {
        guard let view = views[owner], let track = tracks[owner] else { return }
        guard !rendered.contains(owner) else { return }
        track.add(view)
        rendered.insert(owner)
    }

    /// detachRenderer 把 owner 的视图从它的轨道上摘下来。**重复调用安全。**
    private func detachRenderer(owner: String, view: IMAspectVideoView) {
        guard rendered.remove(owner) != nil else { return }
        tracks[owner]?.remove(view)
    }

    private func makeRenderView(owner: String) -> IMAspectVideoView {
        let view = IMAspectVideoView(frame: .zero)
        view.owner = owner
        return view
    }

    /// onMain 保证在主线程执行。**用 async 不用 sync**（CONVENTIONS §5 禁止 main.sync）；
    /// 已经在主线程时直接跑，免得挂载比调用方晚一个 runloop。
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

/**
 会自己决定「裁切填满还是留黑边」的渲染视图。

 判据是 `imShouldFillVideo`（纯算术，在 Engine 里，有单测）：
 裁切后画面还剩 ≥ 56.25% 可见就填满，否则留边。
 规则与真机依据见 `im-rtc-server/docs/mechanism/VIDEO_RENDERING.md`（五仓统一）。

 # 为什么要自己算，不让界面层传

 `IMCallKit` 只依赖 `IMCallEngine`、够不到这个类，传不了「此刻是九宫格还是全屏」。
 而判据只要两个尺寸就够——**九宫格里竖屏源正好落在阈值上、仍然满格无黑边**
 （这是第一版「一律 FIT」被推翻的原因：那样九宫格白留两条宽黑边）；
 **竖屏全屏里横屏源只剩 28% 可见，才留黑边**（填满会是 3 倍放大 + 砍掉七成）。

 # 两个触发点都要接

 · 视频尺寸变了（对端转屏、换摄像头）→ `RTCVideoViewDelegate`；
 · 自己的 bounds 变了（进出全屏、九宫格行列变化、设备转屏）→ `layoutSubviews`。
   少接任何一个，都会在那种变化之后停在上一次算出来的模式上。

 自己当自己的 delegate：这个视图没有别的观察者，多一层转发只会多一处能漂的地方。
 */
final class IMAspectVideoView: RTCMTLVideoView, RTCVideoViewDelegate {

    /// 这块画布登记在谁名下（uid 或 `:local:cid`）。只用来打日志。
    var owner = ""

    /// 最近一次拿到的视频尺寸。**已经旋转过**——iOS 的 delegate 给的就是显示尺寸
    /// （与 Android 不同，那边给的是未旋转缓冲区 + 旋转角）。
    private var videoSize: CGSize = .zero

    /// 这块画布已经打过几行「画面尺寸变化」。见 ``logSizeChange(from:to:)``。
    private var sizeLogs = 0
    private static let maxSizeLogs = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        applyContentMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 storyboard 构造") }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyContentMode()
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        let previous = videoSize
        videoSize = size
        applyContentMode()
        logSizeChange(from: previous, to: size)
    }

    /**
     inheritVideoSize 新画布一出生就按旧画布的视频尺寸算填充模式（摄像头关掉换画布时用）。

     不继承的话新画布尺寸是 0，`imShouldFillVideo` 按「没量出来」先给填满；而尺寸回调是
     异步回主线程的，可能晚于第一次绘制——横屏源在竖屏格子里就会先裁切填满一帧、再跳成留边。
     与 Android `IMVideoFitter.mount`（挂上时先按记下的尺寸算一次）同一个做法。
     */
    func inheritVideoSize(from other: IMAspectVideoView) {
        videoSize = other.videoSize
        applyContentMode()
    }

    /// 尺寸**真的变了**才打（第一次拿到尺寸不算），每块画布最多 `maxSizeLogs` 行：
    /// 远端画布整通复用，对端每换一次层就变一次，不封顶会刷屏。
    private func logSizeChange(from previous: CGSize, to size: CGSize) {
        guard previous != .zero, previous != size, sizeLogs < Self.maxSizeLogs else { return }
        sizeLogs += 1
        IMRTCLog.info("画面尺寸变化", [
            "owner": owner,
            "from": "\(Int(previous.width))x\(Int(previous.height))",
            "to": "\(Int(size.width))x\(Int(size.height))",
        ])
    }

    private func applyContentMode() {
        let fill = imShouldFillVideo(
            videoWidth: Double(videoSize.width), videoHeight: Double(videoSize.height),
            viewWidth: Double(bounds.width), viewHeight: Double(bounds.height))
        let wanted: UIView.ContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        // 判重：`videoContentMode` 的 setter 会触发重绘，而 layoutSubviews 调得很勤。
        guard videoContentMode != wanted else { return }
        videoContentMode = wanted
    }
}
#endif
