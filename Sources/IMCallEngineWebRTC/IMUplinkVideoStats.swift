#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import WebRTC
import IMCallEngine

/**
 通话中**开关摄像头前后**的上行视频采样。只为排查一件事：iOS 重开摄像头之后，
 Android 那边「画面已经出来了，又刷新一下」（2026-09-11 真机，iOS 档位降到 720p 也没减轻）。

 # 要它回答的问题

 那一下刷新在接收端长得都一样，发送端的原因却各不相同，而且此前没有任何日志看得出来：
 · 编码器先按低分辨率出、再升回来——`frameWidth` 变、`qualityLimitationResolutionChanges` 涨；
 · 恢复之后很快又编了一个关键帧——`keyFramesEncoded` 涨两次，`pliCount` / `firCount` 涨说明是对端或 SFU 要的；
 · 采集刚起、帧率还没上来（`capture.framesPerSecond`），或码率被卡着（`availableOutgoingBitrate` / `targetBitrate`）。
 和 Android 那边的「下行视频采样」「远端视频恢复后」以及服务端日志按时间对起来看。

 # 为什么不像 Android 那样常驻轮询

 Android 的 `IMUplinkStats` 5 秒一拍、变了才打；刷新发生在重开后的头一两秒，5 秒一拍抓不住。
 这里只挂在「开关摄像头」这一个用户动作上：关的时候 1 行做基线，开的时候在 0 / 1 / 3 / 6 秒各 1 行。
 **一次开关 5 行，按不按由用户决定**（CONVENTIONS §6「正常一通电话最多出现几次」）。

 下一次开关（或挂断）会取消上一轮还没到点的采样，两轮不会交错。
 统计回调在 libwebrtc 的信令线程上，只拼一行日志，不碰每帧每包那条路。
 */
final class IMUplinkVideoStats: @unchecked Sendable {

    /// 重开摄像头后第几秒采样。0 是「采集刚要起、还没出帧」的基线。
    static let reopenOffsets = [0, 1, 3, 6]

    /// 上行视频（outbound-rtp）要看的字段，按 rid 加前缀（`h.frameWidth`）。缺席的不写（见 `imStatsFields`）。
    ///
    /// 要分层：档位里配了三层 encoding，统计里就可能有三条 outbound-rtp（虽然本仓用的包 simulcast
    /// 没真生效，见 current_task.md「已知坑」第一条）——不分层的话后一条会把前一条盖掉。
    static let outboundKeys = [
        "frameWidth", "frameHeight", "framesPerSecond", "framesEncoded", "framesSent",
        "keyFramesEncoded", "hugeFramesSent", "qualityLimitationReason", "qualityLimitationResolutionChanges",
        "targetBitrate", "bytesSent", "pliCount", "firCount", "nackCount", "retransmittedPacketsSent",
        "totalPacketSendDelay", "encoderImplementation",
    ]

    private let queue = DispatchQueue(label: "com.imrtc.engine.media.uplink-stats")
    /// 还没到点的采样。**只在 `queue` 上动。**
    private var pending: [DispatchWorkItem] = []

    /// sample 立刻采一次（关摄像头时的基线），并取消上一轮还没到点的。
    func sample(_ connection: RTCPeerConnection?, phase: String) {
        guard let connection else { return }
        queue.async {
            self.cancelPending()
            Self.collect(connection, phase: phase)
        }
    }

    /// burst 重开摄像头之后按 `reopenOffsets` 采一轮。
    func burst(_ connection: RTCPeerConnection?) {
        guard let connection else { return }
        queue.async {
            self.cancelPending()
            for offset in Self.reopenOffsets {
                // 弱引用：挂断后 PeerConnection 会被整个换掉，别让一条迟到的采样把旧的留住。
                let item = DispatchWorkItem { [weak connection] in
                    guard let connection else { return }
                    Self.collect(connection, phase: "开摄像头+\(offset)s")
                }
                self.pending.append(item)
                self.queue.asyncAfter(deadline: .now() + .seconds(offset), execute: item)
            }
        }
    }

    /// cancel 取消还没到点的采样（挂断时调）。
    func cancel() {
        queue.async { self.cancelPending() }
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending = []
    }

    private static func collect(_ connection: RTCPeerConnection, phase: String) {
        connection.statistics { report in
            var fields = ["phase": phase]
            for stats in report.statistics.values {
                let video = stats.values["kind"] as? String == "video"
                switch stats.type {
                case "outbound-rtp" where video:
                    let rid = stats.values["rid"] as? String ?? "-"
                    fields.merge(imStatsFields(stats.values, keys: Self.outboundKeys, prefix: "\(rid).")) { _, new in new }
                case "media-source" where video:
                    fields.merge(imStatsFields(stats.values, keys: ["width", "height", "framesPerSecond"],
                                               prefix: "capture.")) { _, new in new }
                case "candidate-pair" where (stats.values["nominated"] as? NSNumber)?.boolValue == true:
                    fields.merge(imStatsFields(stats.values,
                                               keys: ["availableOutgoingBitrate", "currentRoundTripTime"])) { _, new in new }
                default:
                    break
                }
            }
            IMRTCLog.info("上行视频采样", fields)
        }
    }
}
#endif
