import Foundation

/*
 门面的媒体那一组：探权限、发布、预览、静音、扬声器、翻转、挂视图、报层上界。
 从 `IMCallEngine.swift` 拆出来（体量红线，CONVENTIONS §2：一个类型的不同关注点拆 extension）。
 按类型的开关（`openMicrophone` 等）在 IMCallEngine+MediaSwitches.swift，预览停止在 IMCallEngine+Preview.swift。
 */

extension IMCallEngine {
    /**
     probeMicrophone 在拨出 / 接听**之前**探一下麦克风权限（交互稿 §01，四端同名）。

     不占设备；被拒抛 `2001`、没设备抛 `2002`，并同时走一遍 `onError`——
     宿主只监听回调表也该知道「这通电话是因为没权限才没打出去」。
     摄像头那一侧用 `startLocalPreview` 探：它本来就该在拨出时起来给人看见自己。
     */
    @objc public func probeMicrophone() async throws {
        do {
            try await requireMedia().probeMicrophone()
        } catch let error as IMRTCError {
            dispatcher.emit(IMEmittedEvent("onError", [
                "code": .int(Int64(error.code.rawValue)),
                "name": .string(error.code.name),
            ]))
            throw error
        }
    }

    /**
     publishMicrophone 发布麦克风，返回轨道的 cid。

     顺序是**先拿轨道再发 publish**：msid 的第二段就是 cid，服务端靠它认领
     m-line（协议 §3.2），所以不能先想一个 cid。
     */
    @objc public func publishMicrophone() async throws -> String {
        let info = try await requireMedia().acquireMicrophone()
        await publish(info, simulcast: false)
        return info.cid
    }

    /**
     startLocalPreview 只起本端采集、**不发布**，返回轨道 cid。

     用来在拨出/来电阶段就让人看见自己——那时还没有房间，推流无从谈起。
     随后的 `publishCamera()` 会复用同一条轨道，不会把摄像头开两次。
     */
    @objc public func startLocalPreview() async throws -> String {
        try await requireMedia().startLocalPreview().cid
    }

    /// publishCamera 发布摄像头，返回轨道的 cid。
    @objc public func publishCamera(simulcast: Bool = true) async throws -> String {
        let info = try await requireMedia().acquireCamera(simulcast: simulcast)
        await publish(info, simulcast: simulcast)
        return info.cid
    }

    /**
     setMuted 开关本端某条轨道。

     **这不是 unpublish**：轨道与协商都保留，只是停止发包。
     反复开关摄像头走 unpublish 会触发重协商风暴（协议 §3.2）。
     */
    /// - Note: 第二个参数**必须带标签**：两个都不带的话生成的 ObjC 选择器是
    ///   `setMuted::completionHandler:`，宿主写出来是 `[engine setMuted:cid :YES ...]`
    ///   那种带空标签的怪东西。（Demo 里那段 ObjC 编译检查就是干这个的。）
    @objc public func setMuted(_ cid: String, muted: Bool) async {
        media?.setMuted(cid, muted)
        guard let trackID = await loop.ctx.room.publishTrackIDs[cid] else { return }
        await loop.dispatch(.act(op: "mute", args: [
            "track_id": .string(trackID), "muted": .bool(muted),
        ]))
    }

    /// setSpeakerOn 切换扬声器 / 听筒（设计文档 §7.5 的 `setAudioRoute`）。
    ///
    /// 没有媒体适配器时静默忽略：纯信令形态的 Engine 没有音频可路由。
    @objc public func setSpeakerOn(_ on: Bool) {
        media?.setSpeakerOn(on)
    }

    /**
     switchCamera 前后摄像头翻转（设计文档 §7.5）。

     **不重新协商**：换的是同一条轨道的采集源，`track_id` / `cid` 都不变，
     服务端与对端不需要知道。没有媒体适配器、或只有一个摄像头时静默忽略。
    */
    /// 当前用的是不是前置摄像头。**本端预览要不要镜像全看它**（后置绝不能镜像）。
    @objc public var isUsingFrontCamera: Bool { media?.isUsingFrontCamera ?? true }

    @objc public func switchCamera() async {
        await media?.switchCamera()
    }

    /// attachView 把某个 uid 的远端画面挂到视图上；传 nil 卸载。
    ///
    /// **这是 UI 拿到画面的唯一途径**（CONVENTIONS §1）：Kit 不许自己碰
    /// PeerConnection，也不该自己拼流。换媒体实现时界面一行不用改。
    @objc public func attachView(_ uid: String, to view: AnyObject?) {
        media?.attachRemoteView(uid, view)
    }

    /// attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 卸载。
    @objc public func attachLocalView(_ cid: String, to view: AnyObject?) {
        media?.attachLocalView(cid, view)
    }

    /**
     setRemoteLayer 报某人画面的**层上界**（协议 §3.5：上界不是命令）。

     九宫格缩略图报 `l`、双击放大报 `h`。**不触发重协商**，也不保证立刻切——
     服务端要等目标层的关键帧，还会再按带宽估计压一次。
     */
    @objc public func setRemoteLayer(_ uid: String, layer: String) async {
        for (trackID, info) in await loop.ctx.room.remoteTracks
        where info.uid == uid && info.kind == "video" {
            await loop.dispatch(.act(op: "update_layer", args: [
                "track_id": .string(trackID), "max_layer": .string(layer),
            ]))
        }
    }

    /// publish 发 `room.publish` 并按轨道类型记「发布过没有」的账（见 `publishedMicCID`）。
    private func publish(_ info: IMLocalTrackInfo, simulcast: Bool) async {
        await loop.dispatch(.act(op: "publish", args: [
            "cid": .string(info.cid),
            "kind": .string(info.kind),
            "source": .string(info.source),
            "simulcast": .bool(simulcast),
        ]))
        // **两条入口共用同一份账**：不管这次发布是 publishMicrophone/publishCamera 自己调的，
        // 还是 openMicrophone/openCamera 触发的，都要落到这里——否则先 publishMicrophone
        // 再 openMicrophone 会因为「open 那边不知道已经发布过」而重复发布一路。
        stateQueue.sync {
            switch info.kind {
            case "audio": publishedMicCID = info.cid
            case "video": publishedCameraCID = info.cid
            default: break
            }
        }
    }
}
