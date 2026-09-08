import Foundation

/// 握手失败该不该一次就放弃，放弃的话按哪种原因抛给宿主。返回 `nil` = 照常退避重连。
///
/// **不可重试 ≠ 参数不对**，三类的处置完全不同，合成一类等于给宿主一条错的建议：
///
/// | 码 | 抛什么 | 宿主该做什么 |
/// |---|---|---|
/// | 1101 `token_invalid` | ``IMKickedOutReason/authExpired`` | **换一枚票再来**。签名密钥轮换、票被吊销都长这样，而换票正好救得了 |
/// | 1104 `kicked_out` | ``IMKickedOutReason/takenOver`` | 回登录页。服务端的吊销名单走的就是「`sys.error{1104}` + 4403」这一对 |
/// | 1004 / 1006 / 1106 … | ``IMKickedOutReason/configRejected`` | 去改配置。换票和重试都救不了——`device_id` 里那个空格不会因为再来一次就没了 |
///
/// 判据仍然是错误码表里的 `retryable`，不在这里另立一张名单——那张表是四端共用的
/// 一致性向量的一部分（`error_codes.json`），另立名单等于给它开了个后门。
///
/// # 两条边界
///
/// 1. **local 组的码不是服务端的裁决。** ``IMSignalConnection/close()`` 会拿 `2005 invalid_state`
///    （它 `retryable == false`）把在飞的握手结掉，那是宿主自己按的退出。
///    不挡掉的话一次正常的 `logout()` 会报成「服务端拒了你的参数」——
///    而静默续期正是先 `logout()` 再换票，会当场变成把人踹回登录页。
///    超时（2004）与断线（2003）也在 local 组，照常走重连。
/// 2. **本端不认识的码信帧上自带的 `retryable`**（见 ``IMRTCError/unknownCodeRetryable``），
///    不能拿折算后的 1501 当真——那样服务端新加的终局码会退化成无限重连。
///
/// # 为什么不像 4401 那样给三次机会
///
/// 4401 给三次是因为「票刚好过期」换一枚新票就能好，而重连时宿主可能已经
/// `updateToken` 了。这里不一样：**`device_id` 里有个空格这件事，重连一万次
/// 它还是有空格**。给三次机会只是把同一条错误在日志里刷三遍，把真正的原因埋掉。
func handshakeGiveUpReason(_ error: IMRTCError) -> IMKickedOutReason? {
    guard !error.code.isLocal else { return nil }
    // 未知码优先信帧上那一位；连帧上都没有就当可重试，维持「不认识就先退避着」的老行为。
    let retryable = error.unknownCodeRetryable ?? error.code.isRetryable
    guard !retryable else { return nil }
    switch error.code {
    case .tokenInvalid: return .authExpired
    case .kickedOut: return .takenOver
    default: return .configRejected
    }
}
