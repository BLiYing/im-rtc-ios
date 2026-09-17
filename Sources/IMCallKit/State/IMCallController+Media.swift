import Foundation
#if canImport(UIKit)
import UIKit
#endif
import IMCallEngine

/*
 本端媒体：麦克风 / 摄像头开关、进房后推流、切后台暂停摄像头。

 从 `IMCallController.swift` 拆出来（体量红线，CONVENTIONS §2：一个类型的不同关注点拆 extension）。
 这几件事共用同一组记账（`micCID` / `cameraCID` / `cameraPublished` / `cameraPausedByBackground`），
 状态中枢那边只负责在「进房了、该推流了」时调一次 `publishFor(mediaType:)`。
 */

extension IMCallController {
    @objc public func toggleMic() {
        let on = !state.selfState.micOn
        apply(.setMic(on))
        guard !micCID.isEmpty else { return }
        Task { await setMutedLogged(micCID, muted: !on) }
    }

    /// 开关摄像头。**还没进房时只改界面，不去发布**；禁用态点了要出提示，不能静默（规范 §06）。
    @objc public func toggleCamera() {
        if state.selfState.cameraBlocked {
            apply(.hint("没有摄像头权限"))
            return
        }
        let on = !state.selfState.cameraOn
        apply(.setCamera(on))
        // 摄像头还没推上房间就关掉（来电页 / 拨出中 / 进了房还没发出去）：**真停采集**，灯立刻灭（设计 v3.7）。
        if !on, !cameraPublished {
            stopLocalPreview()
            return
        }
        guard !state.roomID.isEmpty else {
            // 群通话拨出中打开摄像头：权限拨出前问过了，这时起预览好让人看见自己。
            // 来电页不在这里起：状态一变界面就重画，重画时 `startRingingPreviewIfAllowed` 会起。
            if on, state.phase == .outgoing { Task { await self.startPreviewIfWanted() } }
            return
        }
        Task {
            // 第一次开摄像头要真的发布；之后只是开关，**不走 unpublish**（协议 §3.2 的重协商风暴）。
            // 判「发布过没有」不看 cid：来电页上起过的预览也有 cid，但从没推上去（见 `cameraPublished`）。
            guard !cameraPublished, on else {
                if cameraPublished { await setMutedLogged(cameraCID, muted: !on) }
                return
            }
            do {
                let cid = try await engine.publishCamera() // 有预览轨道时引擎直接复用它
                cameraCID = cid
                cameraPublished = true
                // 发布的这几百毫秒里用户又把摄像头关了：已经推上去的只能停采集，不补这一下灯就一直亮着。
                if await MainActor.run(body: { !self.state.selfState.cameraOn }) {
                    await setMutedLogged(cid, muted: true)
                }
                await MainActor.run { self.broadcast() }
            } catch {
                /*
                 **发布失败要落到界面上。** 原先是 `try?` 吞掉：抛 2001（用户刚在系统设置里
                 关掉摄像头）时按钮已经乐观地点亮了，**用户以为自己出镜了，对端什么也没收到**。
                 */
                IMRTCLog.warn("[Kit] 开摄像头失败", ["err": String(describing: error)])
                await MainActor.run {
                    self.apply(.setCamera(false))
                    imCameraFailureActions(error).forEach(self.apply)
                }
            }
        }
    }

    func publishFor(mediaType: String) async {
        micCID = (try? await engine.publishMicrophone()) ?? ""
        // **本端摄像头是关着的就不推**：关着接听 = 以语音接听，连开都不开。
        let wantsCamera = await MainActor.run { self.state.selfState.cameraOn }
        if mediaType == "video", wantsCamera {
            do {
                cameraCID = try await engine.publishCamera()
                cameraPublished = true
            } catch {
                IMRTCLog.warn("[Kit] 摄像头推流失败，本通只有声音", ["err": String(describing: error)])
                await MainActor.run { imCameraFailureActions(error).forEach(self.apply) }
            }
        }
        // 发布是异步的，**这期间用户完全可能已经点过静音或关摄像头**——补一遍，否则界面显示「已静音」而对方照样听得见。
        let wanted = await MainActor.run { self.state.selfState }
        if !micCID.isEmpty, !wanted.micOn { await setMutedLogged(micCID, muted: true) }
        if !wanted.cameraOn {
            // 推上去了就停采集、留轨道；还只是预览（没推成）就整个停掉——只关轨道的话灯不灭。
            if cameraPublished {
                await setMutedLogged(cameraCID, muted: true)
            } else if !cameraCID.isEmpty {
                await MainActor.run { self.stopLocalPreview() }
            }
        }
        await MainActor.run { self.broadcast() }
    }

    /// setMutedLogged 开关本端轨道。本端在发帧之前就已经切过了；`room.mute` 被拒只留痕，按钮以本端为准。
    func setMutedLogged(_ cid: String, muted: Bool) async {
        do { try await engine.setMuted(cid, muted: muted) } catch { imLogRejected("开关轨道", error) }
    }

    // MARK: - 前后台

    /**
     切后台自动暂停本端视频、回前台恢复（交互稿 §03）。

     iOS 在后台**不允许继续采集摄像头**，对端看到的就是一片黑——比看到头像糟糕得多。
     所以进后台就把摄像头轨道 mute 掉（对端收到「摄像头已关闭」，看到头像）；
     回前台**恢复到用户原来的选择**：他进后台前本来就关着摄像头，回前台不要替他打开。
     */
    func observeAppLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    @objc private func appDidEnterBackground() {
        guard !cameraCID.isEmpty, state.selfState.cameraOn else { return }
        cameraPausedByBackground = true
        Task { await setMutedLogged(cameraCID, muted: true) }
    }

    @objc private func appWillEnterForeground() {
        guard cameraPausedByBackground else { return }
        cameraPausedByBackground = false
        guard !cameraCID.isEmpty, state.selfState.cameraOn else { return }
        Task { await setMutedLogged(cameraCID, muted: false) }
    }
}
