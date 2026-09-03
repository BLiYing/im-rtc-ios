import Foundation

/// 房间状态机的**下行帧**分支。
///
/// 与 RoomStateMachine.swift 拆开是体量红线（CONVENTIONS §2）；
/// 「上行动作」与「下行帧」本来也是两组独立的关注点。
extension IMRoomMachine {
    static func reduceRecv(_ ctx: IMRoomContext, _ type: String,
                           _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        switch type {
        case IMEnvelope.okType(IMFrameType.roomJoin):
            return handleJoinOK(ctx, data)

        case IMEnvelope.okType(IMFrameType.roomLeave):
            return out(cleared(.idle),
                       emit: [IMEmittedEvent("onRoomLeft", ["room_id": .string(ctx.roomID)])])

        case IMEnvelope.okType(IMFrameType.roomPublish):
            return handlePublishOK(ctx, data)

        case IMFrameType.roomAnswer:
            // 服务端对 pub offer 的应答：本端那条上行协商完成了。
            var next = ctx
            next.publish = promote(ctx.publish, from: .publishing, to: .published)
            return out(next)

        case IMFrameType.roomOffer:
            return handleSubOffer(ctx, data)

        case IMEnvelope.okType(IMFrameType.roomUnpublish):
            var next = ctx
            next.publish = drop(ctx.publish, state: .unpublishing)
            return out(next)

        case IMEnvelope.okType(IMFrameType.roomUnsubscribe):
            var next = ctx
            next.subscribe = drop(ctx.subscribe, state: .unsubscribing)
            return out(next)

        case IMFrameType.roomParticipantJoined:
            return out(ctx, emit: [IMEmittedEvent("onUserEnter",
                                                  ["uid": .string(Wire.string(data, "uid"))])])

        case IMFrameType.roomParticipantLeft:
            return handleParticipantLeft(ctx, data)

        case IMFrameType.roomTrackPublished:
            return handleTrackPublished(ctx, data)

        case IMFrameType.roomTrackUnpublished:
            return handleTrackUnpublished(ctx, data)

        case IMFrameType.roomTrackMuted:
            let kind = Wire.string(data, "kind") == "video" ? "video" : "audio"
            return out(ctx, emit: [availability(kind: kind, uid: Wire.string(data, "uid"),
                                                available: !Wire.bool(data, "muted"))])

        case IMFrameType.roomActiveSpeakers:
            return out(ctx, emit: [IMEmittedEvent("onActiveSpeakers",
                                                  ["speakers": data["speakers"] ?? .array([])])])

        case IMFrameType.roomQuality:
            return out(ctx, emit: [IMEmittedEvent("onNetworkQuality",
                                                  ["entries": data["entries"] ?? .array([])])])

        case IMFrameType.roomClosed:
            return out(cleared(.idle), emit: [IMEmittedEvent("onRoomClosed", [
                "room_id": .string(Wire.string(data, "room_id")),
                "reason": .string(Wire.string(data, "reason")),
            ])])

        default:
            // 其余的 .ok（subscribe / update_layer / mute）不改状态也不抛回调。
            return out(ctx)
        }
    }

    /// handleJoinOK 用快照把房间一次性搭起来：先成员，再他们的 Track。
    private static func handleJoinOK(_ ctx: IMRoomContext,
                                     _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        var emit = [IMEmittedEvent("onRoomJoined", ["room_id": .string(Wire.string(data, "room_id"))])]
        var next = ctx
        next.state = .joined
        next.roomID = Wire.string(data, "room_id")
        next.participantID = Wire.string(data, "participant_id")

        for participant in objects(data["participants"]) {
            emit.append(IMEmittedEvent("onUserEnter",
                                       ["uid": .string(Wire.string(participant, "uid"))]))
        }
        for track in objects(data["tracks"]) {
            let trackID = Wire.string(track, "track_id")
            let kind = Wire.string(track, "kind") == "video" ? "video" : "audio"
            let uid = Wire.string(track, "uid")
            next.remoteTracks[trackID] = IMRemoteTrack(
                uid: uid, kind: kind, participantID: Wire.string(track, "participant_id"))
            emit.append(availability(kind: kind, uid: uid, available: !Wire.bool(track, "muted")))
            // 自动订阅是**服务端**做的，客户端这边只记账，等 sub offer 来把它们坐实。
            if ctx.autoSubscribe { next.subscribe[trackID] = .subscribing }
        }
        // 进房成功之后**立刻重放 joining 期间攒下的意图**（不变量 R2）：
        // 宿主在 onCallBegin 里就发起的 publish 走的正是这条路。
        let replayed = replayBuffered(next)
        return out(replayed.state, send: replayed.send, emit: emit + replayed.emit)
    }

    private static func handlePublishOK(_ ctx: IMRoomContext,
                                        _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        var next = ctx
        next.publishTrackIDs[Wire.string(data, "cid")] = Wire.string(data, "track_id")
        // 拿到 track_id 之后才发 pub offer：服务端要靠 msid 里的 cid 认领 m-line（§3.2）。
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomOffer,
                                                ["pc": .string("pub"), "sdp": .string("")])])
    }

    /// handleSubOffer：**sub PC 的 offerer 恒为服务端**（§3.3），我们只负责应答。
    /// 应答的同时把「订阅中」坐实为「已订阅」——那条流这时才真的挂上来。
    private static func handleSubOffer(_ ctx: IMRoomContext,
                                       _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        guard Wire.string(data, "pc") == "sub" else { return out(ctx) }
        var next = ctx
        next.subscribe = promote(ctx.subscribe, from: .subscribing, to: .subscribed)
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomAnswer,
                                                ["pc": .string("sub"), "sdp": .string("")])])
    }

    private static func handleParticipantLeft(_ ctx: IMRoomContext,
                                              _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let participantID = Wire.string(data, "participant_id")
        var next = ctx
        for (trackID, track) in ctx.remoteTracks where track.participantID == participantID {
            // 人走了，他的 Track 与我们对它的订阅一起清掉——
            // 不清的话重连时会重放一个死订阅。
            next.remoteTracks.removeValue(forKey: trackID)
            next.subscribe.removeValue(forKey: trackID)
        }
        return out(next, emit: [IMEmittedEvent("onUserLeave",
                                               ["uid": .string(Wire.string(data, "uid"))])])
    }

    private static func handleTrackPublished(_ ctx: IMRoomContext,
                                             _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let trackID = Wire.string(data, "track_id")
        let kind = Wire.string(data, "kind") == "video" ? "video" : "audio"
        let uid = Wire.string(data, "uid")

        var next = ctx
        next.remoteTracks[trackID] = IMRemoteTrack(
            uid: uid, kind: kind, participantID: Wire.string(data, "participant_id"))
        if ctx.autoSubscribe { next.subscribe[trackID] = .subscribing }

        return out(next, emit: [availability(kind: kind, uid: uid,
                                             available: !Wire.bool(data, "muted"))])
    }

    /// handleTrackUnpublished：帧里**不带 kind**，只能靠本地记账知道该抛音频还是视频事件。
    private static func handleTrackUnpublished(_ ctx: IMRoomContext,
                                               _ data: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let trackID = Wire.string(data, "track_id")
        let known = ctx.remoteTracks[trackID]
        var next = ctx
        next.remoteTracks.removeValue(forKey: trackID)
        next.subscribe.removeValue(forKey: trackID)

        guard let known else { return out(next) }
        return out(next, emit: [availability(kind: known.kind, uid: known.uid, available: false)])
    }

    /// availability 把「Track 有没有」翻译成 §7.5 的两个回调之一。
    private static func availability(kind: String, uid: String, available: Bool) -> IMEmittedEvent {
        IMEmittedEvent(kind == "video" ? "onUserVideoAvailable" : "onUserAudioAvailable",
                       ["uid": .string(uid), "available": .bool(available)])
    }

    private static func promote<T: Equatable>(_ map: [String: T], from: T, to: T) -> [String: T] {
        map.mapValues { $0 == from ? to : $0 }
    }

    private static func drop<T: Equatable>(_ map: [String: T], state: T) -> [String: T] {
        map.filter { $0.value != state }
    }

    private static func objects(_ value: IMJSON?) -> [[String: IMJSON]] {
        (value?.arrayValue ?? []).compactMap(\.objectValue)
    }
}
