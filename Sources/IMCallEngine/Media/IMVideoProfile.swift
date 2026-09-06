import Foundation

/*
 视频画质档位。

 # 为什么是「宿主给」而不是「服务端下发」

 与换 token 是同一条边界（协议 §1.5）：**策略归宿主，Engine 不自己去要。**
 画质该多高取决于宿主的业务（付费档位、当前网络、机型），Engine 不认识那些东西。
 宿主要「后台可控」就把这个值放进自己的配置接口里下发给 App——
 那正是宿主后台该管的事，也不需要动 RTC 协议。

 （真要让 **RTC 服务端**统一下发，那是往 `sys.hello.ok.limits` 加字段，
 等于改五个仓 + 一致性向量，是单独一刀，不该混在别的改动里。）

 # 档位怎么定

 分辨率按主流三档；码率取的是 simulcast 最高层的目标值（协议 §3.5 的表）。
 **`maxBitrateBps` 必须和服务端 `internal/sfu/bwe.go` 的 `bitrateHigh` 对得上**：
 那边拿它做带宽预算，两边不一致的话，带宽估计会按一个错的数字去决定降不降层。
 三端（Web 的 `media/videoProfile.ts`、这里、以后的 Android）用同一张表。
 */
@objc(IMVideoProfile)
public final class IMVideoProfile: NSObject {
    /// 档位名，只用于日志。
    @objc public let name: String
    @objc public let width: Int
    @objc public let height: Int
    @objc public let frameRate: Int
    /// 最高层的目标码率。simulcast 的 m / l 层按 1/3、1/10 折算。
    @objc public let maxBitrateBps: Int

    @objc public init(name: String, width: Int, height: Int, frameRate: Int, maxBitrateBps: Int) {
        self.name = name
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.maxBitrateBps = maxBitrateBps
        super.init()
    }

    @objc public static let p360 = IMVideoProfile(
        name: "360p", width: 640, height: 360, frameRate: 24, maxBitrateBps: 500_000)
    @objc public static let p720 = IMVideoProfile(
        name: "720p", width: 1280, height: 720, frameRate: 30, maxBitrateBps: 1_500_000)
    @objc public static let p1080 = IMVideoProfile(
        name: "1080p", width: 1920, height: 1080, frameRate: 30, maxBitrateBps: 3_000_000)

    /// 缺省档位。**1080p 在九宫格里没有意义**，只是白烧上行带宽。
    @objc public static let `default` = IMVideoProfile.p720

    /// 三个预设，按分辨率从低到高。界面拿它列档位（与 Android 的 `IMVideoProfile.PRESETS` 同名同序）。
    @objc public static let presets: [IMVideoProfile] = [p360, p720, p1080]

    /// simulcastEncodings 三层的码率：h 满额、m 三分之一、l 十分之一（协议 §3.5）。
    /// 返回的是 (rid, 缩放倍数, 码率)，由媒体层翻成 `RTCRtpEncodingParameters`。
    public var simulcastLayers: [(rid: String, scaleDownBy: Double, bitrateBps: Int)] {
        [("h", 1, maxBitrateBps), ("m", 2, maxBitrateBps / 3), ("l", 4, maxBitrateBps / 10)]
    }
}
