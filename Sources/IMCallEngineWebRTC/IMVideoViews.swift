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

/// 一次性的第一帧探针。**收到第一帧就自己摘下来**，不留在渲染链路上。
final class IMFirstFrameProbe: NSObject, RTCVideoRenderer {
    private let onFirstFrame: () -> Void
    private var fired = false
    private let lock = NSLock()

    init(onFirstFrame: @escaping () -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {
        // 尺寸回调也可能先于第一帧到，**不能拿它当判据**——它只说明协商出了分辨率。
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let alreadyFired = fired
        fired = true
        lock.unlock()
        guard !alreadyFired else { return }
        onFirstFrame()
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

    /// attach 把某个 owner 的画面挂到宿主给的视图上；传 nil 卸载。
    ///
    /// **重复调用是幂等的**。原先每调一次就 `addSubview` 一个新的
    /// `RTCMTLVideoView`——而 Kit 每次状态变化都会重挂一遍，于是格子里
    /// 叠了一摞渲染视图，只有最下面那张接着轨道。
    func attach(owner: String, to container: UIView?) {
        onMain { [self] in
            guard let container else {
                if let view = views[owner] {
                    detachRenderer(owner: owner, view: view)
                    view.removeFromSuperview()
                }
                views[owner] = nil
                return
            }
            let view = views[owner] ?? makeRenderView()
            if view.superview !== container {
                view.removeFromSuperview()
                view.frame = container.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(view)
            }
            views[owner] = view
            attachRenderer(owner: owner)
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
            views = [:]
            tracks = [:]
            orphans = [:]
            owners = [:]
            rendered = []
        }
    }

    // MARK: - 内部（全部在主线程）

    private func bind(owner: String, track: RTCVideoTrack) {
        // 同一个 owner 换了轨道（对方关了摄像头再开）：**先把旧轨道从渲染视图上摘掉**，
        // 不摘的话新轨道的帧会和旧轨道的最后一帧抢同一个渲染器，画面停在旧的那一帧。
        if let previous = tracks[owner], previous !== track, let view = views[owner] {
            previous.remove(view)
            rendered.remove(owner)
        }
        tracks[owner] = track
        attachRenderer(owner: owner)
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

    private func makeRenderView() -> IMAspectVideoView { IMAspectVideoView(frame: .zero) }

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

    /// 最近一次拿到的视频尺寸。**已经旋转过**——iOS 的 delegate 给的就是显示尺寸
    /// （与 Android 不同，那边给的是未旋转缓冲区 + 旋转角）。
    private var videoSize: CGSize = .zero

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
        videoSize = size
        applyContentMode()
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
