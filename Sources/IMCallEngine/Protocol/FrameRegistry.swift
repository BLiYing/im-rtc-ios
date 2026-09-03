import Foundation

/*
 帧类型注册表，对应 `RTC_PROTOCOL.md` 附录 A 的帧索引。

 「加一个帧」的完整动作是：改协议文档 → 改 docs/conformance 向量 → 在这里注册 → 四仓跟进。
 **顺序不许颠倒**（§9）。
 */
public enum IMFrameType {
    // sys 域
    public static let hello = "sys.hello"
    public static let ping = "sys.ping"
    public static let pong = "sys.pong"
    public static let error = "sys.error"

    // room 域：上行请求
    public static let roomJoin = "room.join"
    public static let roomLeave = "room.leave"
    public static let roomPublish = "room.publish"
    public static let roomUnpublish = "room.unpublish"
    public static let roomMute = "room.mute"
    public static let roomSubscribe = "room.subscribe"
    public static let roomUnsubscribe = "room.unsubscribe"
    public static let roomUpdateLayer = "room.update_layer"
    // 下面三个是**双向**的：谁是请求方由 pc 字段决定（§3.3），不由 type 决定。
    public static let roomOffer = "room.offer"
    public static let roomAnswer = "room.answer"
    public static let roomICECandidate = "room.ice_candidate"

    // room 域：下行事件
    public static let roomParticipantJoined = "room.participant_joined"
    public static let roomParticipantLeft = "room.participant_left"
    public static let roomTrackPublished = "room.track_published"
    public static let roomTrackUnpublished = "room.track_unpublished"
    public static let roomTrackMuted = "room.track_muted"
    public static let roomActiveSpeakers = "room.active_speakers"
    public static let roomQuality = "room.quality"
    public static let roomClosed = "room.closed"

    // call 域：上行请求
    public static let callInvite = "call.invite"
    public static let callAccept = "call.accept"
    public static let callReject = "call.reject"
    public static let callCancel = "call.cancel"
    public static let callHangup = "call.hangup"
    public static let callInviteMore = "call.invite_more"
    public static let callJoin = "call.join"

    // call 域：下行事件
    public static let callIncoming = "call.incoming"
    public static let callRinging = "call.ringing"
    public static let callAccepted = "call.accepted"
    public static let callRejected = "call.rejected"
    public static let callBusy = "call.busy"
    public static let callNoAnswer = "call.no_answer"
    public static let callCancelled = "call.cancelled"
    public static let callConnected = "call.connected"
    public static let callHandledElsewhere = "call.handled_elsewhere"
    public static let callEnded = "call.ended"
}

public enum IMFrameRegistry {
    /// 全部上行请求帧。请求必须带非空 req_id，且**恰好**有一条应答。
    ///
    /// room.offer / answer / ice_candidate **不在这张表里**——它们是双向的。
    public static let requestTypes: Set<String> = [
        IMFrameType.hello, IMFrameType.ping,
        IMFrameType.roomJoin, IMFrameType.roomLeave, IMFrameType.roomPublish,
        IMFrameType.roomUnpublish, IMFrameType.roomMute, IMFrameType.roomSubscribe,
        IMFrameType.roomUnsubscribe, IMFrameType.roomUpdateLayer,
        IMFrameType.callInvite, IMFrameType.callAccept, IMFrameType.callReject,
        IMFrameType.callCancel, IMFrameType.callHangup, IMFrameType.callInviteMore,
        IMFrameType.callJoin,
    ]

    /// §3.6 的会议层留位帧：**已占名但 v1 不实现**。
    ///
    /// 客户端不该发它们；收到服务端的 1003 时要能分清「将来会有」与「压根没有」。
    public static let reservedTypes: Set<String> = [
        "room.mute_participant", "room.kick", "room.lock", "room.raise_hand",
        "room.participant_muted", "room.participant_kicked", "room.hand_raised", "room.locked",
    ]

    /// isRequest 报告这个 type 是不是上行请求帧。
    public static func isRequest(_ type: String) -> Bool { requestTypes.contains(type) }

    /// isReserved 报告这个 type 是不是已占名但未实现的会议层帧。
    public static func isReserved(_ type: String) -> Bool { reservedTypes.contains(type) }

    /// fields 返回某帧类型的字段声明；未知帧返回 nil。
    ///
    /// 请求帧的 `.ok` 如果没单独登记，一律给空对象——纯 ack 是常态，
    /// 不必为每个 `room.mute.ok` 写一份声明。
    public static func fields(for type: String) -> IMFrameFields? {
        if let direct = registry[type] { return direct }
        if type.hasSuffix(IMEnvelope.okSuffix) {
            let base = String(type.dropLast(IMEnvelope.okSuffix.count))
            if isRequest(base) { return SysFrames.empty }
        }
        return nil
    }

    /// knownTypes 列出全部显式登记的帧类型（不含自动派生的纯 ack `.ok`），供测试核对。
    public static var knownTypes: [String] { Array(registry.keys) }

    private static let registry: [String: IMFrameFields] = {
        var table: [String: IMFrameFields] = [
            IMFrameType.hello: SysFrames.hello,
            IMEnvelope.okType(IMFrameType.hello): SysFrames.helloOK,
            IMFrameType.ping: SysFrames.empty,
            IMFrameType.pong: SysFrames.empty,
            IMFrameType.error: SysFrames.error,

            IMFrameType.roomJoin: RoomFrames.join,
            IMEnvelope.okType(IMFrameType.roomJoin): RoomFrames.joinOK,
            IMFrameType.roomLeave: RoomFrames.leave,
            IMFrameType.roomPublish: RoomFrames.publish,
            IMEnvelope.okType(IMFrameType.roomPublish): RoomFrames.publishOK,
            IMFrameType.roomUnpublish: RoomFrames.trackID,
            IMFrameType.roomMute: RoomFrames.mute,
            IMFrameType.roomSubscribe: RoomFrames.layer,
            IMFrameType.roomUnsubscribe: RoomFrames.trackID,
            IMFrameType.roomUpdateLayer: RoomFrames.layer,
            IMFrameType.roomOffer: RoomFrames.sdp,
            IMFrameType.roomAnswer: RoomFrames.sdp,
            // room.offer 没有 .ok —— pub 侧的 offer 由 room.answer 直接作为应答回来（§3.3）。
            IMEnvelope.okType(IMFrameType.roomAnswer): SysFrames.empty,
            IMFrameType.roomICECandidate: RoomFrames.iceCandidate,
            IMEnvelope.okType(IMFrameType.roomICECandidate): SysFrames.empty,

            IMFrameType.roomParticipantJoined: RoomFrames.participantJoined,
            IMFrameType.roomParticipantLeft: RoomFrames.participantLeft,
            IMFrameType.roomTrackPublished: RoomFrames.trackPublished,
            IMFrameType.roomTrackUnpublished: RoomFrames.trackUnpublished,
            IMFrameType.roomTrackMuted: RoomFrames.trackMuted,
            IMFrameType.roomActiveSpeakers: RoomFrames.activeSpeakers,
            IMFrameType.roomQuality: RoomFrames.quality,
            IMFrameType.roomClosed: RoomFrames.closed,
        ]
        // 分两段写不是风格问题：单个字典字面量太长时 Swift 的类型检查器会指数级变慢。
        let callTable: [String: IMFrameFields] = [
            IMFrameType.callInvite: CallFrames.invite,
            IMEnvelope.okType(IMFrameType.callInvite): CallFrames.inviteOK,
            IMFrameType.callAccept: CallFrames.callID,
            IMEnvelope.okType(IMFrameType.callAccept): SysFrames.empty,
            IMFrameType.callReject: CallFrames.callID,
            IMFrameType.callCancel: CallFrames.callID,
            IMFrameType.callHangup: CallFrames.callID,
            IMFrameType.callInviteMore: CallFrames.inviteMore,
            IMEnvelope.okType(IMFrameType.callInviteMore): SysFrames.empty,
            IMFrameType.callJoin: CallFrames.callID,
            IMEnvelope.okType(IMFrameType.callJoin): SysFrames.empty,

            IMFrameType.callIncoming: CallFrames.incoming,
            IMFrameType.callRinging: CallFrames.ringing,
            IMFrameType.callAccepted: CallFrames.memberOutcome,
            IMFrameType.callRejected: CallFrames.memberOutcome,
            IMFrameType.callBusy: CallFrames.memberOutcome,
            IMFrameType.callNoAnswer: CallFrames.memberOutcome,
            IMFrameType.callCancelled: CallFrames.cancelled,
            IMFrameType.callConnected: CallFrames.connected,
            IMFrameType.callHandledElsewhere: CallFrames.handledElsewhere,
            IMFrameType.callEnded: CallFrames.ended,
        ]
        table.merge(callTable) { current, _ in current }
        return table
    }()
}

extension IMEnvelope {
    /// decodedData 按帧声明把 data 补齐默认值、校验类型。
    ///
    /// 未知帧类型抛 `unknownType`——**不静默放行**：放行等于让上层拿到一个
    /// 没人校验过的字典，那种数据迟早以奇怪的方式崩在别处。
    public func decodedData() throws -> [String: IMJSON] {
        guard let fields = IMFrameRegistry.fields(for: type) else {
            if IMFrameRegistry.isReserved(type) {
                throw IMRTCError(.notImplemented, "\(type) 是会议层留位帧，v1 不实现")
            }
            throw IMRTCError(.unknownType, "未知帧类型 \(type)")
        }
        return try FieldCodec.decode(fields, data)
    }
}
