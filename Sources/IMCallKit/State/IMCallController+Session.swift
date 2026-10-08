import Foundation
import IMCallEngine

/*
 Kit 取票登录的接线（server `docs/design/KIT_TOKEN_PROVIDER_DESIGN.md`）：把 `IMKitSession` 接到
 主线程、系统联网状态与真 Engine 上。配了 `IMCallKitConfig.tokenProvider` 才有会话；
 **没配就什么都不做**——宿主自己管登录，行为与 2.1.x 一致。会话只在主线程上碰。
 */
extension IMCallController: IMSessionEngine {
    func sessionLogin(_ token: String, done: @escaping (Error?) -> Void) {
        enqueueEngineOp { [engine] in
            do {
                try await engine.login(token)
                DispatchQueue.main.async { done(nil) }
            } catch {
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    func sessionLogout() {
        enqueueEngineOp { [engine] in await engine.logout() }
    }

    /**
     会话发给 Engine 的 logout / login **一个接一个地跑**：每个操作等上一个跑完再开始。

     这两个都是 async，原先各起一个独立的 `Task`，先后没有保证。2026-10-08 真机（iPhone 14 Pro）：
     登录前那一下「清场 logout」与紧随其后的 login 交错——logout 读连接时还是 nil（没东西可关），
     login 起了帧泵、建了连接，logout 的后半段 `stopFramePump()` 才跑，把新帧泵掐了。
     连接还活着、请求的应答照常（走连接自己的 pending 表），**服务端推下来的帧（来电、对方拒接、
     通话结束）全被丢掉**：呼叫发得出去，对方拒接这边不知道，别人打来也不响。
     Android 的 Engine 把 login / logout 投递到同一个调度队列，Web 的 logout 是同步的，都没有这个问题。
     **只在主线程调**（链头 `engineOps` 只在主线程读写）。
     */
    func enqueueEngineOp(_ op: @escaping @Sendable () async -> Void) {
        let previous = engineOps
        engineOps = Task {
            await previous?.value
            await op()
        }
    }

    func sessionUpdateToken(_ token: String, expiresAtMS: Int64) {
        engine.updateToken(token, expiresAtMS: expiresAtMS)
    }

    func sessionNotifyNetworkChanged() {
        engine.notifyNetworkChanged()
    }
}

extension IMCallController {
    /// 起会话（取票登录）。**主线程调**。没有 provider 时只把旧会话停掉。
    func startSession(provider: IMTokenProvider?) {
        stopSession()
        guard let provider else { return }
        let session = IMKitSession(
            engine: self,
            provider: provider,
            schedule: { delayMS, task in
                let item = DispatchWorkItem(block: task)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMS), execute: item)
                return { item.cancel() }
            },
            isOnline: { [weak self] in self?.networkOnline ?? true },
            mainThread: { task in DispatchQueue.main.async(execute: task) })
        kitSession = session
        session.start()
    }

    /// 停会话（会登出 Engine）。**主线程调**。没有会话时空操作。
    func stopSession() {
        kitSession?.stop()
        kitSession = nil
    }

    /// `IMCallKit.ensureReady` 的实现。没配 tokenProvider 恒为 true。主线程回调。
    func ensureReady(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard let session = self.kitSession else { completion(true); return }
            session.ensure { completion($0 == nil) }
        }
    }

    /**
     发帧之前确保已登录（设计 §6）：等待期间界面照常是「正在呼叫…」/「接通中…」。
     登不上就把 `screen` 那一屏收起（还在的话；nil = 还没出界面）、弹一句提示，返回 false。
     */
    func readyOrNotice(screen: IMCallPhase?) async -> Bool {
        let failure: IMKitFailure? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let session = self.kitSession else { continuation.resume(returning: nil); return }
                session.ensure { continuation.resume(returning: $0) }
            }
        }
        guard let failure else { return true }
        IMRTCLog.warn("[Kit] 通话服务没登上，不发帧", ["failure": failure == .network ? "network" : "service"])
        await MainActor.run {
            if let screen, self.state.phase == screen { self.apply(.dismiss) }
            self.showNotice(imT(failure.hintKey))
        }
        return false
    }
}
