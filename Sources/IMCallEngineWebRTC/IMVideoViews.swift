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

/// 画面挂载表：uid ↔ 渲染视图 ↔ 轨道。
///
/// 三者的到达顺序**没有保证**：宿主可能先挂视图（界面先出来了），
/// 也可能轨道先到（对方先推流）。所以两边都要能「等对方」——
/// 只处理一种顺序的话，另一种顺序下就是黑屏且不报错。
final class IMVideoRegistry {
    private var views: [String: RTCMTLVideoView] = [:]
    private var tracks: [String: RTCVideoTrack] = [:]
    private let lock = NSLock()

    /// attach 把某个 uid 的画面挂到宿主给的视图上；传 nil 卸载。
    func attach(uid: String, to container: UIView?) {
        lock.lock()
        let existing = views[uid]
        let track = tracks[uid]
        lock.unlock()

        // 卸载：**必须把轨道从渲染视图上摘掉**，否则解码器还占着（CONVENTIONS §7 成对清理）。
        if container == nil {
            existing.map { view in
                track?.remove(view)
                view.removeFromSuperview()
            }
            lock.lock(); views[uid] = nil; lock.unlock()
            return
        }
        guard let container else { return }

        let renderView = existing ?? makeRenderView()
        if renderView.superview !== container {
            renderView.removeFromSuperview()
            renderView.frame = container.bounds
            renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(renderView)
        }
        lock.lock(); views[uid] = renderView; lock.unlock()
        track?.add(renderView)
    }

    /// bind 把一条远端轨道认到某个 uid 上；视图已经挂好就立刻接上。
    func bind(uid: String, track: RTCVideoTrack) {
        lock.lock()
        tracks[uid] = track
        let view = views[uid]
        lock.unlock()
        view.map { track.add($0) }
    }

    func removeAll() {
        lock.lock()
        let pairs = views
        let boundTracks = tracks
        views = [:]
        tracks = [:]
        lock.unlock()
        for (uid, view) in pairs {
            boundTracks[uid]?.remove(view)
            view.removeFromSuperview()
        }
    }

    private func makeRenderView() -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        // **等比裁切铺满**（草图 §03 的「COVER」）：留黑边比裁掉一点更难看。
        view.videoContentMode = .scaleAspectFill
        return view
    }
}
#endif
