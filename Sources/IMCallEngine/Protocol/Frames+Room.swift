import Foundation

/// room 域：房间与媒体。见 §3。
/// **Room 层是媒体的全部**——1v1、群通话、会议都用同一套帧。
enum RoomFrames {
    private static let E = IMProtocolEnums.self

    /// 房间成员快照。
    static let participant: IMFrameFields = [
        "participant_id": .string(),
        "uid": .string(),
        "device_id": .string(),
        "joined_at_ms": .int(),
    ]

    /// 一条已发布 Track 的快照。
    static let track: IMFrameFields = [
        "track_id": .string(),
        "participant_id": .string(),
        "uid": .string(),
        "kind": .enumeration(values: E.trackKinds, fallback: "audio"),
        "source": .enumeration(values: E.trackSources, fallback: "microphone"),
        "codec": .string(),
        // 空数组 = 单层。**不能是 null**。
        "simulcast_layers": .enumArray(values: E.layers, fallback: "l"),
        "muted": .bool(),
    ]

    /// 进房请求。
    ///
    /// **注意 auto_subscribe / publish_audio 默认是 true**：直接发零值 data，
    /// 线路上会变成 false，人进了房却收不到任何流。发送侧一律从 `defaults` 起手。
    static let join: IMFrameFields = [
        "room_id": .string(),
        "room_token": .string(),
        "auto_subscribe": .bool(defaultValue: true),
        "publish_audio": .bool(defaultValue: true),
        "publish_video": .bool(defaultValue: false),
    ]

    /// 带回整个房间的快照，客户端据此一次性把九宫格搭起来。
    static let joinOK: IMFrameFields = [
        "room_id": .string(),
        "room_kind": .enumeration(values: E.roomKinds, fallback: "call_group"),
        "participant_id": .string(),
        "max_participants": .int(),
        "joined_at_ms": .int(),
        "participants": .objectArray(fields: participant),
        "tracks": .objectArray(fields: track),
    ]

    /// 离房请求。
    static let leave: IMFrameFields = ["room_id": .string()]

    /// 发布请求。
    ///
    /// cid 是**客户端**生成的本地 track 标识，必须出现在随后 pub offer 的 msid 里；
    /// 服务端靠它把 SDP 的 m-line 认回 track_id。
    static let publish: IMFrameFields = [
        "cid": .string(),
        "kind": .enumeration(values: E.trackKinds, fallback: "audio"),
        "source": .enumeration(values: E.trackSources, fallback: "microphone"),
        "simulcast": .bool(),
        "width": .int(),
        "height": .int(),
        "max_bitrate_kbps": .int(),
    ]

    /// 回带 track_id 与原样回显的 cid 供配对。
    static let publishOK: IMFrameFields = ["track_id": .string(), "cid": .string()]

    /// 只带 track_id 的帧（unpublish / unsubscribe）。
    static let trackID: IMFrameFields = ["track_id": .string()]

    /// 开关麦克风/摄像头。**这不是 unpublish**，Track 与协商都保留。
    static let mute: IMFrameFields = ["track_id": .string(), "muted": .bool()]

    /// 订阅与换层。max_layer 是**上界不是命令**。
    static let layer: IMFrameFields = [
        "track_id": .string(),
        "max_layer": .enumeration(values: E.layers, fallback: "l", defaultValue: "m"),
    ]

    /// room.offer 与 room.answer 共用。
    static let sdp: IMFrameFields = [
        "pc": .enumeration(values: E.pcRoles, fallback: "pub"),
        "sdp": .string(),
    ]

    /// trickle ICE 候选。candidate 为 "" 表示收集结束，**接收方必须容忍**。
    static let iceCandidate: IMFrameFields = [
        "pc": .enumeration(values: E.pcRoles, fallback: "pub"),
        "candidate": .string(),
        "sdp_mid": .string(),
        "sdp_mline_index": .int(),
    ]

    /// 有人进房。
    static let participantJoined: IMFrameFields = [
        "room_id": .string(),
        "participant_id": .string(),
        "uid": .string(),
        "device_id": .string(),
        "joined_at_ms": .int(),
    ]

    /// 有人离房。reason 取 §6 的子集。
    static let participantLeft: IMFrameFields = [
        "room_id": .string(),
        "participant_id": .string(),
        "uid": .string(),
        "device_id": .string(),
        "reason": .enumeration(values: E.reasons, fallback: "error"),
        "duration_sec": .int(),
    ]

    /// 有人发布了 Track。
    static let trackPublished: IMFrameFields = track.merging(["room_id": .string()]) { current, _ in current }

    /// 有人销毁了 Track。
    static let trackUnpublished: IMFrameFields = [
        "room_id": .string(),
        "track_id": .string(),
        "participant_id": .string(),
        "uid": .string(),
    ]

    /// 对应 onUserAudioAvailable / onUserVideoAvailable。
    static let trackMuted: IMFrameFields = [
        "room_id": .string(),
        "track_id": .string(),
        "participant_id": .string(),
        "uid": .string(),
        "kind": .enumeration(values: E.trackKinds, fallback: "audio"),
        "muted": .bool(),
    ]

    /// 一个正在说话的人。volume 0~100，**整数**。
    static let speaker: IMFrameFields = [
        "participant_id": .string(),
        "uid": .string(),
        "volume": .int(min: 0, max: 100),
    ]

    /// 服务端节流 300ms，客户端**不得**依赖更高频率。
    static let activeSpeakers: IMFrameFields = [
        "room_id": .string(),
        "speakers": .objectArray(fields: speaker),
    ]

    /// 一个人的网络质量，level 0~6。
    static let qualityEntry: IMFrameFields = [
        "participant_id": .string(),
        "uid": .string(),
        // 越界折成 0 = unknown，**不是钳到 6**——把未知说成「已断开」会误导 UI。
        "level": .int(min: 0, max: 6, outOfRange: IMProtocolEnums.qualityUnknown),
    ]

    /// 服务端节流 2s。
    static let quality: IMFrameFields = [
        "room_id": .string(),
        "entries": .objectArray(fields: qualityEntry),
    ]

    /// 房间结束。
    static let closed: IMFrameFields = [
        "room_id": .string(),
        "reason": .enumeration(values: E.reasons, fallback: "error"),
        "duration_sec": .int(),
    ]
}
