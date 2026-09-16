import Foundation

/*
 通话路由变化之后要不要**补一次强制外放**——纯判据，macOS 上 `swift test` 就能跑（理由同 `IMVideoFit`）。

 iOS 的扬声器键走 `overrideOutputAudioPort(.speaker / .none)`：`.none` 是把路由交还系统，
 插耳机、连蓝牙系统会自己切过去，这一半本来就是「跟随系统」。缺的是另一半——
 **插拔耳机 / 蓝牙时系统会把 `.speaker` 覆盖清掉**，而 Kit 的扬声器键还亮着，
 界面说外放、声音却在耳机或听筒里（CLIENT_PARITY `[^audioroute]`：原先没监听 `routeChangeNotification`）。

 取值用 `AVAudioSession.RouteChangeReason` 的 rawValue 与 `AVAudioSession.Port` 的字符串，
 不引 AVFoundation：Engine 这一层要在 macOS 上编。与 Android `IMAudioRoutePolicy` 同一条规矩：
 强制外放时插拔不改路由，按钮亮着声音就在扬声器；关着时交给系统。
 */

/// 设备插拔引起的路由变化（`newDeviceAvailable` = 1、`oldDeviceUnavailable` = 2）。
let imRouteChangeDeviceReasons: Set<UInt> = [1, 2]

/// `AVAudioSession.Port.builtInSpeaker` 的字符串值。
let imBuiltInSpeakerPort = "Speaker"

/**
 imShouldReapplySpeaker：这次路由变化之后要不要重新 `overrideOutputAudioPort(.speaker)`。

 只在三条同时成立时补：用户要外放、是设备插拔引起的（别的原因——比如我们自己刚改完覆盖——不接，免得自激）、
 此刻输出里已经没有扬声器了。
 */
public func imShouldReapplySpeaker(wantsSpeaker: Bool, reason: UInt, outputPorts: [String]) -> Bool {
    wantsSpeaker && imRouteChangeDeviceReasons.contains(reason) && !outputPorts.contains(imBuiltInSpeakerPort)
}
