#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import UIKit
import WebRTC
import IMCallEngine

/*
 画面：远端 / 本端挂视图、认领远端轨道归属、收下行轨道。从 IMWebRTCAdapter.swift 拆出来（体量红线，CONVENTIONS §2）。
 登记表 `registry` 自己管线程（整张表只在主线程上动）；读 `localTracks` 进 `lock`。
 */

extension IMWebRTCAdapter {
    public func attachRemoteView(_ uid: String, _ view: AnyObject?) {
        // 线程由登记表自己管（它整张表只在主线程上动）。
        registry.attach(owner: uid, to: view as? UIView)
    }

    /**
     attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 只从容器上摘下来，
     视图本身与它的 sink **不销毁**（整通电话复用，见 `IMVideoRegistry.attach(owner:to:)`）。

     **走的是同一张登记表**（键加 `:local:` 前缀），不是另起一套。
     原先这里每调一次就 `addSubview` 一个新的 `RTCMTLVideoView`，
     而 Kit 每次界面状态变化都会重挂一遍——格子里叠了一摞渲染视图，
     且传 nil 时什么都不做，卸载不掉。

     关摄像头再开摄像头走的就是这条路（`view` 非 nil 再传一次），
     不是 `stopLocalPreview`——真正的释放只发生在挂断 / 进房前的
     `stopLocalPreview()`（那两处调用 `registry.remove`/`removeAll`）。
    */
    public func attachLocalView(_ cid: String, _ view: AnyObject?) {
        let key = imLocalViewKey(cid)
        guard let container = view as? UIView else {
            registry.attach(owner: key, to: nil)
            return
        }
        lock.lock()
        let track = localTracks[cid] as? RTCVideoTrack
        lock.unlock()
        if let track { registry.addTrack(cid, track, owner: key) }
        registry.attach(owner: key, to: container)
    }

    /**
     claimRemoteTracks 告诉媒体层「哪条 track_id 是谁的」。

     媒体层自己**无从知道**这件事：`didAdd rtpReceiver` 只带 track_id，
     归属写在信令帧 `room.track_published` 里。两者谁先到都可能，
     所以轨道先按 track_id 收下，归属到了再认领。
    */
    public func claimRemoteTracks(_ owners: [String: String]) {
        for (trackID, uid) in owners { registry.claim(trackID, owner: uid) }
    }

    /// handleRemoteTrack 处理一条下行轨道。
    ///
    /// **track_id 就是协议里的 track_id**：订阅侧 SDP 的 msid 即此值（协议 §2.5 表）。
    func handleRemoteTrack(_ track: RTCMediaStreamTrack) {
        let trackID = track.trackId
        events.onRemoteTrack?(trackID)
        guard let video = track as? RTCVideoTrack else { return }
        // **归属这时候通常还不知道**（信令帧可能后到），先按 track_id 收着，
        // 等 claimRemoteTracks 认领。这里原先直接把 track_id 当 uid 挂进去，
        // 而挂载侧传的是真 uid，两把钥匙永远对不上——协商全通但一格画面都没有。
        registry.addTrack(trackID, video, owner: "")
        // 第一帧探针。**判据是真的出帧**，不是协商完成——提前抛等于让 UI 撤了 loading 去露黑屏。
        let probe = IMFirstFrameProbe { [weak self] _, _, _ in
            self?.events.onFirstVideoFrame?(trackID)
        }
        video.add(probe)
    }
}
#endif
