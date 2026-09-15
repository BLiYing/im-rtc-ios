import Foundation

/**
 `makeConnection` 拆出来是体量红线（CONVENTIONS §2，600 行）——门面主文件本来就顶着，
 这一段本来也是独立的关注点：「怎么把一条 `IMSignalConnection` 接到帧泵与 dispatcher 上」，
 跟 `login()` 本身「校验参数、管理生命周期」不是一回事。
 */
extension IMCallEngine {
    func makeConnection(token: String,
                        inlet: AsyncStream<IMLoopWork>.Continuation) -> IMSignalConnection {
        var options = IMConnectionOptions(url: url, token: token, deviceID: deviceID)
        if let webSocketFactory { options.webSocketFactory = webSocketFactory }
        var events = IMConnectionEvents()
        /*
         **握手结果一律从这里进状态机**，`login()` 不自己喂一遍。

         只在 login 里喂的话，自动重连那次握手就没人接——状态机不知道自己重连了
         （`resumed == false` 时房间与通话不归零、`resumed == true` 时攒下的意图
         不重放），宿主也收不到第二次 didConnect。Web 端实测的症状是：
         服务端重启后换票重连其实成功了，界面却一直停在「重连中」。
         */
        events.onConnected = { [weak self] hello in
            guard let self else { return }
            self.stateQueue.sync { self.myUID = hello.uid }
            inlet.yield(.connected(sessionID: hello.sessionID, resumed: hello.resumed))
        }
        // **进泵，不要各自开 Task**：顺序就是在这里保住的（见 frameInlet）。
        events.onEvent = { type, data in
            inlet.yield(.frame(type, data))
        }
        events.onDisconnected = { [weak self] code, willReconnect in
            guard let self else { return }
            inlet.yield(.disconnected)
            // 关闭码只有连接层知道，所以这一条由它独占上报（见 IMFrameLoop.dispatch）。
            self.dispatcher.emitConnectionEvent(.disconnected, [
                "code": NSNumber(value: code), "will_reconnect": NSNumber(value: willReconnect),
            ])
        }
        events.onKickedOut = { [weak self] reason in
            guard let self else { return }
            // 状态机只认「被踢了」这一件事，走泵（与帧同一个顺序）；
            // **原因是给宿主做处置判断的，由连接层独占上报**——`.takenOver` 要回登录页、
            // `.authExpired` 是换票重来，处置相反，而状态机不可能知道是哪一种。
            inlet.yield(.kickedOut)
            self.dispatcher.emitKickedOut(reason)
        }
        events.onSessionUnrecoverable = {
            inlet.yield(.sessionUnrecoverable)
        }
        events.onTokenWillExpire = { [weak self] expiresAtMS in
            self?.dispatcher.emitTokenWillExpire(expiresAtMS)
        }
        events.onError = { [weak self] error in
            self?.dispatcher.emit(IMEmittedEvent("onError", [
                "code": .int(Int64(error.code.rawValue)),
                "name": .string(error.code.name),
            ]))
        }
        return IMSignalConnection(options: options, events: events)
    }
}
