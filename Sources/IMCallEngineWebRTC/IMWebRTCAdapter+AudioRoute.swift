#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import AVFoundation
import WebRTC
import IMCallEngine

/*
 四条音频路由的枚举与切换（2026-09-22，设计稿 §04 的面板 + §7.5 的 `setAudioRoute`）。

 # 一条铁律：所有会话操作都走 RTCAudioSession

 上一版（系统的 `AVRoutePickerView`）就是栽在这里——它让**系统**去改路由，
 `RTCAudioSession` 全程不知情，而 libwebrtc 的 ADM 正靠那套配置吃饭
 （`IMWebRTCAudioConfiguration` 把 category/mode/采样率都钉死了）。后果是真机上
 两个方向同时没声音，且工厂全进程一份、永不销毁，崩了拔掉蓝牙也不自愈。

 所以这里每一次改动都：`RTCAudioSession.sharedInstance().lockForConfiguration()` 里做、
 用 `session.session` 拿底下那个 `AVAudioSession` 调 `setPreferredInput`、
 **绝不碰 category**（那是 `applyCallAudioCategory` 的事，两边抢会打架）。

 # 两套意图要同步

 `desiredSpeakerOn`（布尔，老的 `setSpeakerOn`）与这里的四态路由是同一件事的两种说法。
 **切路由时必须把布尔一起改掉**，否则 `imShouldReapplySpeaker` 那道插拔兜底会在下一次
 插拔时把用户刚选的蓝牙강行拽回扬声器——两套意图各说各话正是上一版的风险点之一。
 */
extension IMWebRTCAdapter {

    /// 会话还没配好时返回空清单：那时 `availableInputs` 不全（响铃期故意不配会话），
    /// 空清单的语义是「不提供路由选择」，界面据此退回二态开关，不会显示半张错的清单。
    public var availableAudioRoutes: [IMAudioRoute] {
        lock.lock()
        let active = audioSessionActive
        lock.unlock()
        guard active else { return [] }
        return imBuildAudioRoutes(inputs: Self.currentInputDescriptors())
    }

    public var currentAudioRoute: IMAudioRoute? {
        let routes = availableAudioRoutes
        guard !routes.isEmpty else { return nil }
        return imPickCurrentRoute(routes: routes, outputPorts: Self.currentOutputPorts())
    }

    /**
     setAudioRoute 切到指定路由。

     内置扬声器走 `overrideOutputAudioPort(.speaker)`（这条路径与老的 `setSpeakerOn(true)` 同一条）；
     其余三条先撤掉外放覆盖，再用 `setPreferredInput` 指定输入口——输入输出在通话场景是配对的，
     指定了蓝牙麦，输出自然跟着走蓝牙。听筒是「撤掉覆盖 + 选内置麦」的结果，没有单独的 API。

     **切不过去只记日志**：设备可能刚好被拔掉，或系统拒绝（`-50` 之类）。
     绝不让它把通话弄断——顶多声音还在原来那条路上，用户再点一次即可。
     */
    public func setAudioRoute(_ route: IMAudioRoute) {
        lock.lock()
        let active = audioSessionActive
        // 两套意图同步，见文件头部。
        desiredSpeakerOn = route.kind == .speaker
        lock.unlock()
        guard active else {
            IMRTCLog.info("会话还没配好，先记下路由意向", ["kind": String(route.kind.rawValue)])
            return
        }
        applyAudioRoute(route)
        // 系统未必发 routeChangeNotification（比如目标就是当前路由），自己补一次广播，
        // 免得面板上的勾不跟手。
        notifyAudioRoutesChanged()
    }

    /// 真正去改。**只在会话配好之后调**，全程在 `RTCAudioSession` 的锁里。
    /// 只有用户在面板里手动选择才走到这里；通话开始不主动钉路由（见 `ensureAudioSessionConfigured`）。
    private func applyAudioRoute(_ route: IMAudioRoute) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            /*
             **永远显式指定输入口，绝不传 `nil`（2026-09-22 真机根因）。**

             原先外放那一支走的是 `setPreferredInput(nil)`——「撤掉偏好交还系统」。
             蓝牙连着时这一下会把会话**退化成 A2DP（只出不进）**：真机日志里
             `outputs=BluetoothA2DPOutput`、`session.inputs=0`、`totalSamplesDuration=0`，
             麦克风连一个采样都录不到，两个方向同时哑。更糟的是 `preferredInput` 是
             **会话级**设置、通话结束不会自己复位（见 `close()`），所以一通语音里切过外放，
             下一通视频/群通话一开场就是坏的——15:11 那段 `inputs=0` 正是上一通留下的。

             钉住输入口还顺带修好了听筒：`overrideOutputAudioPort(.none)` 的语义是
             「输出交还系统默认」，而蓝牙连着时系统默认就是蓝牙——单靠它选「听筒」等于没切
             （《交互流程》差异 7 早写过这句）。把输入钉在内置麦，输出才会跟着回到听筒。
            */
            /*
             **通话中途绝不改 category**（15:56 真机试过，当场翻车）。

             为了让「选听筒」不被蓝牙抢走，这里一度改成切内置时把 `.allowBluetooth`
             从 options 里摘掉再重设 category。路由确实切对了
             （`outputs=Speaker / route_inputs=MicrophoneBuiltIn`），**但上行当场停死**：
             `pkts` 卡在 119、`dur` 卡在 2.38，二十秒一个包都没再发——
             在通话中途 `setCategory` 会把 libwebrtc 的音频单元踢翻，而它没能自己恢复。
             这正是本文件头部那条「绝不碰 category」的由来，当时只写了理由、没写代价，
             现在有真机代价了：**代价是整条上行**。

             于是蓝牙连着时选「听筒」仍会落到蓝牙（`overrideOutputAudioPort(.none)`
             只把输出交还系统，而系统默认就是蓝牙）。**这是设计行为，不是限制**（用户 2026-09-22
             拍板）：「听筒」这一行的语义就是「不强制外放、交还系统」，系统有蓝牙就走蓝牙。别再想修它。
            */
            try session.session.setPreferredInput(Self.inputPort(for: route))
            // 只有外放要覆盖输出；其余三条撤掉覆盖，让输出跟着上面钉好的输入走。
            try session.overrideOutputAudioPort(route.kind == .speaker ? .speaker : .none)
            /*
             回读输入口一起记：**判这一刀成没成看的是 `inputs`，不是 `outputs`**。
             A2DP 退化时 outputs 看着还挺像样（`BluetoothA2DPOutput`），而 inputs 是空的，
             此时麦克风已经死了。真机排查从这一行的 `route_inputs` 看起。
            */
            IMRTCLog.info("音频路由已切换", [
                "kind": String(route.kind.rawValue), "uid": route.uid, "name": route.name,
                "outputs": Self.currentOutputPorts().joined(separator: ","),
                "route_inputs": imDescribeAudioPorts(AVAudioSession.sharedInstance().currentRoute.inputs),
            ])
        } catch {
            // 切不过去不该让通话失败，见方法注释。
            IMRTCLog.warn("音频路由切换失败", [
                "kind": String(route.kind.rawValue), "uid": route.uid,
                "err": String(describing: error),
            ])
        }
    }

    /// notifyAudioRoutesChanged 把此刻的清单与选中项抛给 Engine（再由它抛给宿主与 Kit）。
    /// `routeDidChange` 与 `setAudioRoute` 都调它，是这条回调的唯一出口。
    func notifyAudioRoutesChanged() {
        let routes = availableAudioRoutes
        let current = routes.isEmpty
            ? nil : imPickCurrentRoute(routes: routes, outputPorts: Self.currentOutputPorts())
        lock.lock()
        let handler = events.onAudioRoutesChanged
        lock.unlock()
        handler?(routes, current)
    }

    /**
     把 `IMAudioRoute` 翻回系统的输入端口。**永远不返回 nil**——内置听筒 / 扬声器用内置麦；
     外接设备按 `portUID` 认（不按类型：接了两只蓝牙时类型分不出是哪一只），
     **找不到就退回内置麦**，绝不是 nil。

     找不到确有其事：用户在面板里点了蓝牙那一行，但那一刻它可能刚好在 HFP/A2DP 之间
     协商，`availableInputs` 里瞬间没有它（16:14:03 真机复现过一次，那时是自动钉路由
     触发的，已经改成不主动钉了；但用户手动选择时同一个时间窗仍然存在，得防）。
     `setPreferredInput(nil)` 是唯一绝对不能传的值——那等于把会话往 A2DP 推。
     内置麦永远在，退回它保证麦克风至少能工作，声音可能暂时没切对，好过没声音。
     */
    private static func inputPort(for route: IMAudioRoute) -> AVAudioSessionPortDescription? {
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        let builtIn = inputs.first { $0.portType == .builtInMic }
        switch route.kind {
        case .earpiece, .speaker:
            return builtIn
        case .wiredHeadset, .bluetooth:
            return inputs.first { $0.uid == route.uid } ?? builtIn
        }
    }

    private static func currentInputDescriptors() -> [(type: String, name: String, uid: String)] {
        (AVAudioSession.sharedInstance().availableInputs ?? [])
            .map { (type: $0.portType.rawValue, name: $0.portName, uid: $0.uid) }
    }

    private static func currentOutputPorts() -> [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
    }
}
#endif
