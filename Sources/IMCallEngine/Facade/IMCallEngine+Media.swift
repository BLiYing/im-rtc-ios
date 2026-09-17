import Foundation

/*
 门面的媒体那一组：探权限、发布、预览、静音、扬声器、翻转、挂视图、报层上界。
 从 `IMCallEngine.swift` 拆出来（体量红线，CONVENTIONS §2：一个类型的不同关注点拆 extension）。
 按类型的开关（`openMicrophone` 等）在 IMCallEngine+MediaSwitches.swift，预览停止在 IMCallEngine+Preview.swift。
 */

extension IMCallEngine {
    /**
     probeMicrophone 在拨出 / 接听**之前**探一下麦克风权限（交互稿 §01，四端同名）。

     不占设备；被拒抛 `2001`、没设备抛 `2002`。**只 throw**，不再同时走 `didFailWithError`
     （2.0.0 起一次失败只从一个出口报，server `docs/design/ACTION_RESULT_DESIGN.md` R3）。
     摄像头那一侧用 `startLocalPreview` 探：它本来就该在拨出时起来给人看见自己。
     */
    @objc public func probeMicrophone() async throws {
        try await requireMedia().probeMicrophone()
    }

    /**
     publishMicrophone 发布麦克风，返回轨道的 cid。

     顺序是**先拿轨道再发 publish**：msid 的第二段就是 cid，服务端靠它认领
     m-line（协议 §3.2），所以不能先想一个 cid。

     **返回 = `room.publish.ok` 落进了状态机**（SDP 协商是随后的连锁帧，失败走 `didFailWithError`）；
     进房中调用时意图被缓存、立即返回。被拒时 throw——通话里被拒还会先收掉整通（`callDidEnd(.error)`）。
     */
    @objc public func publishMicrophone() async throws -> String {
        let info = try await requireMedia().acquireMicrophone()
        try await publish(info, simulcast: false)
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

    /// publishCamera 发布摄像头，返回轨道的 cid。结果语义同 `publishMicrophone`。
    @objc public func publishCamera(simulcast: Bool = true) async throws -> String {
        let info = try await requireMedia().acquireCamera(simulcast: simulcast)
        try await publish(info, simulcast: simulcast)
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
    /// - Note: 本端**先**开关（发帧之前），`room.mute` 被拒不回滚本端；还没拿到 track_id 时只动本端、立即返回。
    ///   `room.mute` 被拒 / 超时时 throw。
    @objc public func setMuted(_ cid: String, muted: Bool) async throws {
        try guardNotDestroyed()
        media?.setMuted(cid, muted)
        guard let trackID = await loop.ctx.room.publishTrackIDs[cid] else { return }
        try await act("mute", ["track_id": .string(trackID), "muted": .bool(muted)])
    }

    /// setSpeakerOn 切换扬声器 / 听筒（设计文档 §7.5 的 `setAudioRoute`）。
    ///
    /// 提示类：不 throw。没有媒体适配器、或 `destroy()` 之后静默忽略。
    @objc public func setSpeakerOn(_ on: Bool) {
        guard !(stateQueue.sync { isDestroyed }) else { return }
        media?.setSpeakerOn(on)
    }

    /**
     switchCamera 前后摄像头翻转（设计文档 §7.5）。

     **不重新协商**：换的是同一条轨道的采集源，`track_id` / `cid` 都不变，
     服务端与对端不需要知道。没有媒体适配器、或只有一个摄像头时静默忽略。
    */
    /// 当前用的是不是前置摄像头。**本端预览要不要镜像全看它**（后置绝不能镜像）。
    @objc public var isUsingFrontCamera: Bool { media?.isUsingFrontCamera ?? true }

    /// 本地设备类：`destroy()` 之后 throw 2005；没有媒体适配器、或只有一个摄像头时静默忽略。
    @objc public func switchCamera() async throws {
        try guardNotDestroyed()
        await media?.switchCamera()
    }

    /// attachView 把某个 uid 的远端画面挂到视图上；传 nil 卸载。
    ///
    /// **这是 UI 拿到画面的唯一途径**（CONVENTIONS §1）：Kit 不许自己碰
    /// PeerConnection，也不该自己拼流。换媒体实现时界面一行不用改。
    /// 清理类：`destroy()` 之后挂新视图是空操作（不再新建渲染视图），卸载照做。
    @objc public func attachView(_ uid: String, to view: AnyObject?) {
        guard view == nil || !(stateQueue.sync { isDestroyed }) else { return }
        media?.attachRemoteView(uid, view)
    }

    /// attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 卸载。`destroy()` 之后规则同 `attachView`。
    @objc public func attachLocalView(_ cid: String, to view: AnyObject?) {
        guard view == nil || !(stateQueue.sync { isDestroyed }) else { return }
        media?.attachLocalView(cid, view)
    }

    /**
     setRemoteLayer 报某人画面的**层上界**（协议 §3.5：上界不是命令）。

     九宫格缩略图报 `l`、双击放大报 `h`。**不触发重协商**，也不保证立刻切——
     服务端要等目标层的关键帧，还会再按带宽估计压一次。

     提示类（界面每次换布局都调，失败宿主也无事可做）：**不 throw**，失败走 `didFailWithError`；
     `destroy()` 之后是空操作。
     */
    @objc public func setRemoteLayer(_ uid: String, layer: String) async {
        guard !(stateQueue.sync { isDestroyed }) else { return }
        for (trackID, info) in await loop.ctx.room.remoteTracks
        where info.uid == uid && info.kind == "video" {
            do {
                try await act("update_layer", ["track_id": .string(trackID), "max_layer": .string(layer)])
            } catch {
                emitUnattributed(error)
            }
        }
    }

    /// publish 发 `room.publish` 并按轨道类型记「发布过没有」的账（见 `publishedMicCID`）。被拒时 throw、不记账。
    private func publish(_ info: IMLocalTrackInfo, simulcast: Bool) async throws {
        try await act("publish", [
            "cid": .string(info.cid),
            "kind": .string(info.kind),
            "source": .string(info.source),
            "simulcast": .bool(simulcast),
        ])
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
