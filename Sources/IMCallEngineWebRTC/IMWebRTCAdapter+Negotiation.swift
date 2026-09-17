#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import UIKit
import WebRTC
import IMCallEngine

/*
 SDP 协商与 ICE：上行 offer / 下行 answer / 远端候选。从 IMWebRTCAdapter.swift 拆出来（体量红线，CONVENTIONS §2）。
 **两条 PC 各有固定 offerer**（协议 §3.3）：pub 由本端 offer、sub 由服务端 offer，所以这里没有 glare 处理。
 读写 `pubICERestartPending` 一律进 `lock`。
 */

extension IMWebRTCAdapter {
    /// wire 把一对新造的 PC 的回调接到事件出口（`ensurePeers()` 每造一对调一次）。
    func wire(_ pcs: IMPeerConnections) {
        pcs.onLocalCandidate = { [weak self] role, candidate in
            self?.events.onLocalCandidate?(role, IMICECandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid ?? "",
                sdpMLineIndex: Int(candidate.sdpMLineIndex)))
        }
        pcs.onStateChange = { [weak self] role, state in
            self?.events.onConnectionStateChange?(role, Self.stateName(state))
        }
        pcs.onRemoteTrack = { [weak self] track in
            self?.handleRemoteTrack(track)
        }
    }

    /// createPubOffer 生成上行 offer。**pub 的 offerer 恒为本端**（协议 §3.3）。
    public func createPubOffer() async throws -> String {
        lock.lock()
        let restart = pubICERestartPending
        pubICERestartPending = false
        lock.unlock()
        if restart { IMRTCLog.info("上行重启 ICE", [:]) }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: restart ? ["IceRestart": "true"] : nil,
            optionalConstraints: nil)
        let offer = try await ensurePeers().pub.offer(for: constraints)
        try await ensurePeers().pub.setLocalDescription(offer)
        return offer.sdp
    }

    /// 见协议里的说明。**置位而不是立刻发帧**：发帧是 Engine 的事。
    public func restartPubICE() {
        lock.lock()
        pubICERestartPending = true
        lock.unlock()
    }

    public func applyPubAnswer(_ sdp: String) async throws {
        try await ensurePeers().setRemoteDescription(
            RTCSessionDescription(type: .answer, sdp: sdp), for: .pub)
    }

    /// answerSubOffer 应答服务端下发的下行 offer。**sub 的 offerer 恒为服务端**。
    /// **2026-09-16 新增**：开头也调 `ensureAudioSessionConfigured()`——服务端推下行 offer 与 Kit 调 `acquireMicrophone` 是两条独立异步路径，前者可能先到，理由见该方法顶部注释。
    public func answerSubOffer(_ sdp: String) async throws -> String {
        ensureAudioSessionConfigured()
        // 取一次局部变量复用：`IMPeerConnections` 是引用类型，自己不会在三步之间
        // 把 pub/sub 换掉——会让 peers 整个换掉的只有 `close()`（调用方持有旧引用即可）。
        let peers = ensurePeers()
        try await peers.setRemoteDescription(
            RTCSessionDescription(type: .offer, sdp: sdp), for: .sub)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await peers.sub.answer(for: constraints)
        try await peers.sub.setLocalDescription(answer)
        return answer.sdp
    }

    public func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws {
        try await ensurePeers().addRemoteCandidate(
            RTCIceCandidate(sdp: candidate.candidate,
                            sdpMLineIndex: Int32(candidate.sdpMLineIndex),
                            sdpMid: candidate.sdpMid.isEmpty ? nil : candidate.sdpMid),
            for: pc)
    }
}
#endif
