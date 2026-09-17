import Foundation

/**
 按类型的媒体开关（2026-09-15，与腾讯 TUICallEngine 同名：`openMicrophone` / `closeMicrophone` /
 `openCamera` / `closeCamera`）。

 给不想自己管「这条轨道发布过没有」的宿主用；`publishMicrophone` / `publishCamera` /
 `setMuted` 仍然保留作高级接口。**两组接口认的是同一份「发布过没有」的状态**
 （`publish(_:simulcast:)` 按 `info.kind` 统一记账，见 `publishedMicCID`/`publishedCameraCID`
 的说明）——先用 `publishMicrophone` 发布过麦克风，再调 `openMicrophone`，会识别出
 「已经发布过」直接走取消静音，不会再发布一路。Kit 内部继续用
 `publishMicrophone`/`publishCamera`/`setMuted`，没有换用这一层。

 - **open** = 这个类型的轨道还没发布过就发布（摄像头有预览轨道时 `acquireCamera` 会直接
   复用它，是 `publishCamera` 现有的逻辑，这里不用管）；已经发布过就只是取消静音，
   不重新协商（协议 §3.2 的重协商风暴）。
 - **close** = 对已经发布的轨道 `setMuted(cid, muted: true)`（不 unpublish）；
   没发布过就什么都不做——**这是空操作，不是错误**，跟 CONVENTIONS 里其它「当前没有
   这个东西」的场景（`stopLocalPreview` 没有媒体适配器时静默忽略）同一个语气。
 */
extension IMCallEngine {
    /// openMicrophone 开麦克风：没发布过就发布，已发布就取消静音。
    @objc public func openMicrophone() async throws {
        let cached: String? = stateQueue.sync { publishedMicCID }
        if let cid = cached {
            try await setMuted(cid, muted: false)
            return
        }
        _ = try await publishMicrophone()
    }

    /// closeMicrophone 关麦克风：停止发包，不 unpublish；没发布过、或 `destroy()` 之后就空操作。
    ///
    /// 清理类，**不 throw**：本端在发帧之前就已经静音，`room.mute` 被拒也不回滚本端（隐私优先），
    /// 错误走 `didFailWithError`。
    @objc public func closeMicrophone() async {
        let cached: String? = stateQueue.sync { isDestroyed ? nil : publishedMicCID }
        guard let cid = cached else { return }
        await muteForClose(cid)
    }

    /// openCamera 开摄像头：没发布过就发布（复用现有预览轨道的逻辑见 `publishCamera`），
    /// 已发布就取消静音。
    @objc public func openCamera() async throws {
        let cached: String? = stateQueue.sync { publishedCameraCID }
        if let cid = cached {
            try await setMuted(cid, muted: false)
            return
        }
        _ = try await publishCamera()
    }

    /// closeCamera 关摄像头：`setMuted(cid, muted: true)`——`IMWebRTCAdapter.setMuted`
    /// 对已发布的摄像头轨道置静音时会真的 `halt` 采集（不是仅仅停止发包），所以这一步
    /// 就是关灯；不 unpublish，没发布过就空操作。
    @objc public func closeCamera() async {
        let cached: String? = stateQueue.sync { isDestroyed ? nil : publishedCameraCID }
        guard let cid = cached else { return }
        await muteForClose(cid)
    }

    /// muteForClose 是 close* 共用的「静音、失败只报 didFailWithError」。
    private func muteForClose(_ cid: String) async {
        do {
            try await setMuted(cid, muted: true)
        } catch {
            emitUnattributed(error)
        }
    }
}
