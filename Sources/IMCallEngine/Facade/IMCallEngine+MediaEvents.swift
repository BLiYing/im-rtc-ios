import Foundation

/*
 媒体层回调的接线。

 从 IMCallEngine.swift 拆出来是体量红线（CONVENTIONS §2）：门面主文件逼近 600 行。
 这一段本来也是独立的关注点——「媒体层告诉我们什么、我们怎么接住」。
 */
extension IMCallEngine {

    func mediaEvents() -> IMMediaAdapterEvents {
        var events = IMMediaAdapterEvents()
        events.onLocalCandidate = { [weak self] pc, candidate in
            guard let self else { return }
            Task { await self.loop.sendCandidate(pc, candidate) }
        }
        events.onConnectionStateChange = { [weak self] pc, state in
            guard let self else { return }
            IMRTCLog.debug("PC 状态", ["pc": pc.wireValue, "state": state])
            /*
             **ICE 失败不是终点，是该重连的信号。**

             `pub` 那条的 offerer 是本端，只能自己救；`sub` 那条由服务端救（协议 §3.3）。
             不救的后果：网抖一下（换 Wi-Fi、进电梯、锁屏久了）人就**永久掉出这通通话**，
             对端格子从此是一块黑，而界面上一切正常、谁也不挂断。
             真机上抓到过两条 PC 从某一刻起五分钟一轮地失败，再没回到 connected。
             重启失败还会再进 failed，于是天然形成一个重试节奏。

             **但重试节奏不能没有尽头**（协议 §7.2）：一律自愈、永不上报的话，宿主从头到尾
             收不到任何信号——上面那段现象会一直挂着，而界面上什么都不会变。
             连续 pubIceGiveUp 次重启后仍判 failed，抛一次 2006；之后继续重试但不再重复抛。
            */
            if pc == .pub, state == "connected" {
                self.resetPubIceGiveUp()
            }
            if pc == .pub, state == "failed" {
                IMRTCLog.info("上行通路失败，重启 ICE", [:])
                if self.notePubIceFailure() {
                    IMRTCLog.warn("上行通路连续重启仍失败，上报宿主", [:])
                    self.emitLocalError(.mediaNegotiationFailed)
                }
                self.media?.restartPubICE()
                Task { await self.loop.dispatch(.act(op: "restart_pub_ice")) }
                return
            }
            if pc == .sub, state == "failed" {
                // sub 那条我们救不了（offerer 是服务端，§3.3），只能立即报给宿主。
                IMRTCLog.warn("下行通路失败，等服务端重启", [:])
                self.emitLocalError(.mediaNegotiationFailed)
                return
            }
            guard pc == .sub, state == "connected" else { return }
            Task { await self.loop.dispatch(.internalEvent(name: "media_ready")) }
        }
        events.onFirstVideoFrame = { [weak self] trackID in
            guard let self else { return }
            Task {
                let uid = await self.loop.uidOf(trackID)
                self.dispatcher.emit(IMEmittedEvent("onFirstVideoFrame", [
                    "uid": .string(uid), "track_id": .string(trackID),
                ]))
            }
        }
        return events
    }
}
