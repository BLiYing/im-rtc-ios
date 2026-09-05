#if canImport(WebRTC)
import Foundation
import WebRTC
import IMCallEngine

/*
 两条 PeerConnection 与它们的候选缓冲。

 # 固定 offerer，所以没有玻璃期（glare）

 pub 的 offerer **恒为本端**，sub 的 offerer **恒为服务端**（协议 §3.3）。
 两边都不会同时发起协商，所以不需要 perfect negotiation / rollback——
 那套东西是为「谁都可能先开口」准备的，我们从协议层面就排除了那种情况。

 # 候选必须缓冲

 **这是 Go 版客户端上花了最久才找到的一个 bug**：远端候选在
 `setRemoteDescription` 之前到达是**常态**（服务端进房即订阅时协商得早），
 而那时 `add(candidate)` 会被直接丢掉。后果不是报错，是**下行连接能不能建立全看运气**——
 服务端的 SDP 里碰巧带上主机候选就通，没带上就永远停在 `new`，
 界面上是「格子在、画面黑」，而且不报任何错。修好之后成功率从 1/6 变成 10/10。
 */
final class IMPeerConnections: NSObject {

    let factory: RTCPeerConnectionFactory
    private(set) var pub: RTCPeerConnection!
    private(set) var sub: RTCPeerConnection!

    /// 还没能交给 PC 的远端候选，按角色分开攒。
    ///
    /// `candidateLock` 同时保护它与「远端描述设了没有」的判断——
    /// **两件事必须原子**：分开判断的话，正好在判断与入队之间设上远端描述，
    /// 这个候选就会永远躺在队列里没人排空。
    private var pending: [IMPCRole: [RTCIceCandidate]] = [.pub: [], .sub: []]
    private var hasRemoteDescription: [IMPCRole: Bool] = [.pub: false, .sub: false]
    private let candidateLock = NSLock()

    var onLocalCandidate: ((IMPCRole, RTCIceCandidate) -> Void)?
    var onRemoteTrack: ((RTCMediaStreamTrack) -> Void)?
    var onStateChange: ((IMPCRole, RTCPeerConnectionState) -> Void)?

    override init() {
        RTCInitializeSSL()
        // 软编解码工厂：**VP8 是 MVP 基线**，同时放行 H.264 让硬编生效（设计文档 §7）。
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
        pub = makeConnection(role: .pub)
        sub = makeConnection(role: .sub)
    }

    func connection(for role: IMPCRole) -> RTCPeerConnection {
        role == .pub ? pub : sub
    }

    private func makeConnection(role: IMPCRole) -> RTCPeerConnection {
        let config = RTCConfiguration()
        // **只用 Unified Plan**：Plan B 早已废弃，而且 simulcast 的 rid 只在
        // Unified Plan 下有意义。
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        // 不配 STUN/TURN：服务端是 ICE-lite 且候选由它下发（协议 §3.3），
        // 本端只需要收集主机候选。将来要打洞时这里加 iceServers。
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints,
                                                      delegate: nil) else {
            fatalError("创建 RTCPeerConnection 失败——这在正常设备上不会发生")
        }
        /*
         **先留强引用再赋值，顺序不能反。**

         `RTCPeerConnection.delegate` 是 weak：`connection.delegate = IMPCDelegate(...)`
         之后那个新建的对象没有任何强引用，当场就被释放，`connection.delegate`
         立刻读回 nil。真机/模拟器上第一次登录就崩在这里
         （`as! IMPCDelegate` 对 nil 强解包）。

         就算不崩——比如写成 `as?` ——症状会更糟：**所有 PC 回调静默消失**，
         候选发不出去、连接状态没人报，界面上是「转圈但永远连不上」。
         */
        let delegate = IMPCDelegate(role: role, owner: self)
        delegates.append(delegate)
        connection.delegate = delegate
        return connection
    }

    /// 强引用 delegate。见上：`RTCPeerConnection.delegate` 是 weak 的。
    private var delegates: [IMPCDelegate] = []

    // MARK: - 描述与候选

    /// setRemoteDescription 设远端描述，**并在同一把锁里排空攒下的候选**。
    func setRemoteDescription(_ sdp: RTCSessionDescription, for role: IMPCRole) async throws {
        try await connection(for: role).setRemoteDescription(sdp)
        let drained: [RTCIceCandidate] = {
            candidateLock.lock()
            defer { candidateLock.unlock() }
            hasRemoteDescription[role] = true
            let queued = pending[role] ?? []
            pending[role] = []
            return queued
        }()
        for candidate in drained {
            try? await connection(for: role).add(candidate)
        }
        if !drained.isEmpty {
            IMRTCLog.debug("排空缓冲候选", ["pc": role.wireValue, "count": String(drained.count)])
        }
    }

    /// addRemoteCandidate 加一个远端候选；远端描述还没设就先攒着。
    func addRemoteCandidate(_ candidate: RTCIceCandidate, for role: IMPCRole) async throws {
        let ready: Bool = {
            candidateLock.lock()
            defer { candidateLock.unlock() }
            if hasRemoteDescription[role] == true { return true }
            pending[role, default: []].append(candidate)
            return false
        }()
        guard ready else { return }
        try await connection(for: role).add(candidate)
    }

    func close() {
        pub.close()
        sub.close()
        candidateLock.lock()
        pending = [.pub: [], .sub: []]
        hasRemoteDescription = [.pub: false, .sub: false]
        candidateLock.unlock()
    }

    deinit {
        RTCCleanupSSL()
    }
}

/// PC 的回调。**每条 PC 一个实例**，这样回调里天然知道自己是 pub 还是 sub——
/// 共用一个 delegate 就得反查是谁在回调，那段反查逻辑没有存在的必要。
private final class IMPCDelegate: NSObject, RTCPeerConnectionDelegate {
    private let role: IMPCRole
    private weak var owner: IMPeerConnections?

    init(role: IMPCRole, owner: IMPeerConnections) {
        self.role = role
        self.owner = owner
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        owner?.onLocalCandidate?(role, candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        owner?.onStateChange?(role, newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        owner?.onRemoteTrack?(track)
    }

    // 下面这些协议要求实现，但我们不需要——**不要在这里打日志**，
    // 有些是每次协商都触发的高频回调。
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {}
}
#endif
