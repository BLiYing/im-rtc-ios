#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import IMCallEngine

/*
 ObjC 宿主拿到「带媒体的 Engine」的工厂（HOST_INTEGRATION_DESIGN §3.3、§7-2 拍板 2026-09-15）。

 # 为什么要有这个工厂

 `IMCallEngine` 的 `@objc` 便利构造器只有 `init(url:deviceID:)`（纯信令，见
 `Sources/IMCallEngine/Facade/IMCallEngine.swift`）——带 `IMMediaAdapter` 的那个
 designated init 参数类型不是 `@objc` 友好的（`IMMediaAdapter` 刻意不是 `@objc` 协议，
 见 CONVENTIONS §4），ObjC 宿主看不见它，也构造不出一台能出声出画的 Engine。

 之前的方案是「ObjC 宿主自己写一个 Swift 小桥」，但首批宿主 IMProgram 是纯 ObjC 工程，
 逼它引入 Swift 只为了这一行构造代价不成比例。所以在这个 iOS-only、已经依赖
 libwebrtc 的 target 里补一个 ObjC 可见的静态工厂，内部用 `IMWebRTCAdapter()`——
 Engine 本身仍然不知道 WebRTC 的存在（依赖方向没变）。
 */
extension IMCallEngine {
    /// webRTCEngine 用默认的 `IMWebRTCAdapter()` 构造一台带媒体的 Engine。
    ///
    /// ObjC 侧：`[IMCallEngine webRTCEngineWithURL:deviceID:]`。
    @objc(webRTCEngineWithURL:deviceID:)
    public static func webRTCEngine(url: URL, deviceID: String) -> IMCallEngine {
        IMCallEngine(url: url, deviceID: deviceID, media: IMWebRTCAdapter())
    }
}
#endif
