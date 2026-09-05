import Foundation

/*
 把状态机产出的**意图**变成线路上真的一帧。

 # 为什么这一层要单独存在

 状态机是纯函数，产不出 SDP——它给的协商帧 `sdp` 字段是空的。
 「取真值填进去」这件事既要碰媒体层又要碰连接：放进状态机会毁掉它的可测性
 （一致性向量就跑不了了），放进门面则让门面同时管路由、填 SDP 和事件三件事。
 所以单独一层——**门面只管把帧交给它，它只管把帧变成真的**。
 */
actor IMFrameSender {
    private let media: IMMediaAdapter?
    /// 服务端最近一次下发的 sub offer。**答复它时才有得可答**。
    private var lastSubOfferSDP = ""

    init(media: IMMediaAdapter?) {
        self.media = media
    }

    /// noteSubOffer 记下服务端下发的 sub offer。
    func noteSubOffer(_ sdp: String) {
        lastSubOfferSDP = sdp
    }

    /**
     send 发一帧并**返回应答**。

     返回而不是自己消化掉：**`.ok` 也要喂回状态机**——`room.join.ok` /
     `room.publish.ok` 都是状态推进的关键一步。漏掉那一半的后果 Web 端实测过：
     `room.join` 发出去了、`.ok` 回来了，房间状态却永远停在 `joining`，
     随后每一次 publish 都被不变量 R1 本地拒成 2005。
     */
    func send(_ connection: IMSignalConnection,
              _ frame: IMOutgoingFrame) async throws -> IMRequestResult? {
        guard let fields = IMFrameRegistry.fields(for: frame.type) else { return nil }

        // **从全默认值起手再覆盖**，不是直接发状态机给的那几个键——
        // 少一个 `auto_subscribe` 就等于把默认的 true 写成 false，
        // 人进了房收不到任何流（§2.4 的发送侧默认值陷阱，三端都踩过）。
        var data = FieldCodec.defaults(fields)
        for (key, value) in frame.data { data[key] = value }

        let pc = frame.data["pc"]?.stringValue ?? ""
        if frame.type == IMFrameType.roomOffer, pc == IMPCRole.pub.wireValue {
            data["sdp"] = .string(try await requireMedia().createPubOffer())
        } else if frame.type == IMFrameType.roomAnswer, pc == IMPCRole.sub.wireValue {
            data["sdp"] = .string(try await requireMedia().answerSubOffer(lastSubOfferSDP))
        }
        return try await connection.request(frame.type, data: data)
    }

    /// sendCandidate 发一个本端候选。
    ///
    /// 候选是**尽力而为**的：失败由调用方转成 error 事件，不中断事件流。
    func sendCandidate(_ connection: IMSignalConnection,
                       _ pc: IMPCRole, _ candidate: IMICECandidate) async throws {
        guard let fields = IMFrameRegistry.fields(for: IMFrameType.roomICECandidate) else { return }
        var data = FieldCodec.defaults(fields)
        data["pc"] = .string(pc.wireValue)
        data["candidate"] = .string(candidate.candidate)
        data["sdp_mid"] = .string(candidate.sdpMid)
        data["sdp_mline_index"] = .int(Int64(candidate.sdpMLineIndex))
        _ = try await connection.request(IMFrameType.roomICECandidate, data: data)
    }

    /// requireMedia 在没有媒体适配器时给出**说得清的**错误。
    ///
    /// 「只要信令、UI 自己画」的宿主完全不给适配器是**正常用法**，
    /// 所以这条路必须是一个明确的错误，不是崩溃、也不是静默的空 SDP。
    ///
    /// 用的是既有的 `2005 invalid_state`（「宿主在错误状态下调 Engine 方法」）——
    /// **不为它新造错误码**：错误码表是四仓共用的契约，加一个码等于改四个仓 + 改向量，
    /// 而这件事本质就是「在不支持的状态下调了方法」，2005 说得准。
    private func requireMedia() throws -> IMMediaAdapter {
        guard let media else {
            throw IMRTCError(.invalidState,
                             "没有媒体适配器：这台 Engine 只做信令，推流/画面需要传入 IMMediaAdapter")
        }
        return media
    }
}
