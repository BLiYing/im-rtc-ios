import Foundation
#if canImport(UIKit)
import AVFoundation
import IMCallEngine

/*
 来电铃声 + 回铃音的播放（2026-09-16）。

 判据在 `IMCallViewRules.swift` 的 `ringtoneFor(_:muted:)`——**纯函数、不带 UIKit**，
 单独放在那个文件里才能被 `swift test` 覆盖到（这个文件全包在 `#if canImport(UIKit)` 里，
 macOS 上编不到，见 CLAUDE.md「Kit 界面代码 macOS 上编不到」）。这里只负责按判据结果
 起停一个 `AVAudioPlayer`，是纯粹的执行层。

 # 挂载点

 唯一挂载点是 `IMCallController.onStateChanged(from:)`——它由 `state` 的 `didSet`
 唯一触发且已经去重。**不要挂到 `IMCallControllerObserver.callController(_:didChange:)`
 上**：`broadcast()` 在 state 没变时也会被调用（`reloadProfiles` / `switchCamera` 等都会触发
 一次 broadcast 而不改 state），挂在那上面会跟着重复触发、反复重开同一个循环播放器。

 # 停铃靠 phase 收敛，不按事件特判

 `.callEnd` 在 `phase == .incoming` 时直接把 state 重置回 `idle`、不经过 `.ended`
 （`IMCallViewState.swift`），`ringtoneFor` 的 `default` 分支本来就同时盖住 `idle` 与
 `ended`，所以这里不需要为「响铃时被挂断」这条路单独处理。
 */
extension IMCallController {
    /// updateRingtone 按当前状态决定该不该响、响哪种；只在 `onStateChanged` 里调一次。
    func updateRingtone() {
        let kind = ringtoneFor(state, muted: config.ringtoneMuted)
        guard kind != ringtoneKind else { return }
        ringtoneKind = kind
        ringtonePlayer?.stop()
        ringtonePlayer = nil
        guard kind != .none else { return }
        guard let url = ringtoneURL(for: kind) else {
            IMRTCLog.warn("[Kit] 铃声资源缺失，不响", ["kind": kind.rawValue])
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            ringtonePlayer = player
        } catch {
            IMRTCLog.warn("[Kit] 铃声播放失败", ["kind": kind.rawValue, "err": String(describing: error)])
        }
    }

    /// ringtoneURL 取宿主给的文件；宿主没给就退回包内置的默认音（`Bundle.module`）。
    private func ringtoneURL(for kind: IMRingtoneKind) -> URL? {
        switch kind {
        case .none:
            return nil
        case .incoming:
            return config.incomingRingtone ?? Self.builtinRingtoneURL
        case .ringback:
            return config.ringbackTone ?? Self.builtinRingbackURL
        }
    }

    private static let builtinRingtoneURL = Bundle.module.url(forResource: "im_ringtone", withExtension: "mp3")
    private static let builtinRingbackURL = Bundle.module.url(forResource: "im_ringback", withExtension: "mp3")
}
#endif
