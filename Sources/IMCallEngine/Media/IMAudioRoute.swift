import Foundation

/*
 音频路由的公开类型与选路纯逻辑（2026-09-22 落地，设计稿 §7.5 的 `setAudioRoute`）。

 **为什么是「设备清单」不是「布尔」**：`setSpeakerOn(Bool)` 表达不了三条以上的路由，
 而设计稿 §04 要求面板里每一行写**设备名**（「AirPods」而不是「蓝牙」）——名字只有系统知道，
 必须由这一层带上来。iOS / Android 两端同名，Web / 桌面不适用（浏览器与桌面没有这个概念）。

 **不引 AVFoundation**：这一层要在 macOS 上 `swift test`（理由同 `IMAudioRoutePolicy`），
 所以端口类型一律用 `AVAudioSession.Port` 的字符串值，真正读会话的地方在 `IMCallEngineWebRTC`。
 */

/// 音频路由的种类（设计稿 §04 的四条）。
@objc public enum IMAudioRouteKind: Int {
    case earpiece = 0
    case speaker = 1
    case wiredHeadset = 2
    case bluetooth = 3
}

/**
 一条可选的音频路由。

 **`name` 只有外接设备才有值**（「AirPods」「车载蓝牙」）；内置听筒 / 扬声器是空串——
 Engine 没有 UI，不做本地化，「听筒」「扬声器」这两个词由 Kit 用自己的文案表取
 （`imT("route.earpiece")` / `imT("route.speaker")`）。界面显示名的规则因此是：
 有 `name` 就用 `name`，没有就按 `kind` 取本地化词。
 */
@objc public final class IMAudioRoute: NSObject, @unchecked Sendable {
    @objc public let kind: IMAudioRouteKind
    /// 系统给的设备名；内置两条为空串。
    @objc public let name: String
    /// 切换时回传的标识。内置两条是下面那两个固定串，外接设备用系统的 `portUID`。
    @objc public let uid: String

    // 三个字段都是 let、构造后不再变，所以 `@unchecked Sendable` 是安全的
    // （NSObject 子类拿不到编译器自动推导的 Sendable）。
    @objc public init(kind: IMAudioRouteKind, name: String, uid: String) {
        self.kind = kind
        self.name = name
        self.uid = uid
        super.init()
    }

    /// 面板要拿它比「当前选中的是哪一行」，所以相等性按 `uid` 走。
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? IMAudioRoute else { return false }
        return uid == other.uid
    }

    public override var hash: Int { uid.hashValue }

    public override var description: String { "IMAudioRoute(\(kind.rawValue), \(uid), \(name))" }
}

/// 内置两条路由的固定 `uid`：它们不是 `availableInputs` 里的端口，没有 `portUID` 可用。
public let imAudioRouteEarpieceUID = "builtin.earpiece"
public let imAudioRouteSpeakerUID = "builtin.speaker"

/// `AVAudioSession.Port` 里算「有线耳机」的输入口。USB 也归这一类（转接头耳机）。
let imWiredHeadsetInputPorts: Set<String> = ["HeadsetMicrophone", "USBAudio"]
/// 算「蓝牙」的输入口。通话只可能走 HFP，A2DP 是只出不进的，不会出现在 `availableInputs` 里。
let imBluetoothInputPorts: Set<String> = ["BluetoothHFP"]

/// `AVAudioSession.Port` 里的输出口字符串，用来判「此刻在用哪一条」。
/// 没有「听筒」那一条：它是认不出别的时的回落值，见 `imCurrentAudioRouteKind`。
let imSpeakerOutputPort = "Speaker"
let imWiredHeadsetOutputPorts: Set<String> = ["Headphones", "USBAudio"]
let imBluetoothOutputPorts: Set<String> = ["BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE"]

/**
 imBuildAudioRoutes 把系统的**可选输入口**清单翻成面板要显示的路由清单。

 **数据源必须是 `availableInputs` 而不是 `currentRoute`**：前者是「能选哪些」，
 后者是「此刻在用哪个」。上一版路由选择器栽的跟头之一就是拿 `currentRoute` 当可选清单，
 结果用户一选内置扬声器，蓝牙那一行就从清单里消失了（设备其实还连着）。

 顺序固定「听筒 / 扬声器 / 有线耳机 / 蓝牙」，与设计稿面板的行序一致；
 内置两条恒在（iPhone 上一定有），外接的有几条列几条。

 下面三个 `public` 是因为 `IMCallEngineWebRTC` 是独立 target，要跨模块调
 （同 `imShouldReapplySpeaker`）；它们是 SDK 内部的工具函数，不在给宿主的 ObjC 面里。
 */
public func imBuildAudioRoutes(inputs: [(type: String, name: String, uid: String)]) -> [IMAudioRoute] {
    var routes = [
        IMAudioRoute(kind: .earpiece, name: "", uid: imAudioRouteEarpieceUID),
        IMAudioRoute(kind: .speaker, name: "", uid: imAudioRouteSpeakerUID),
    ]
    for input in inputs where imWiredHeadsetInputPorts.contains(input.type) {
        routes.append(IMAudioRoute(kind: .wiredHeadset, name: input.name, uid: input.uid))
    }
    for input in inputs where imBluetoothInputPorts.contains(input.type) {
        routes.append(IMAudioRoute(kind: .bluetooth, name: input.name, uid: input.uid))
    }
    return routes
}

/**
 imCurrentAudioRouteKind 按**输出口**判此刻声音从哪出。

 判输出而不是判输入：用户按的是「声音从哪出来」，而强制外放（`overrideOutputAudioPort(.speaker)`）
 只改输出、不改输入——只看输入的话，外放时会错报成「听筒」。
 认不出来时回落到听筒：那是 `.playAndRecord` 不强制外放的默认去处。
 */
public func imCurrentAudioRouteKind(outputPorts: [String]) -> IMAudioRouteKind {
    if outputPorts.contains(where: { imBluetoothOutputPorts.contains($0) }) { return .bluetooth }
    if outputPorts.contains(where: { imWiredHeadsetOutputPorts.contains($0) }) { return .wiredHeadset }
    if outputPorts.contains(imSpeakerOutputPort) { return .speaker }
    return .earpiece
}

/**
 imPickCurrentRoute 从清单里挑出「此刻在用的那一条」，给面板打勾用。

 外接设备按 `kind` 认（同一时刻只可能接一条同类的在用），内置两条按 `kind` 直接取。
 清单里没有对应项时返回 nil——面板就不打勾，总比打错强。
 */
public func imPickCurrentRoute(routes: [IMAudioRoute], outputPorts: [String]) -> IMAudioRoute? {
    let kind = imCurrentAudioRouteKind(outputPorts: outputPorts)
    return routes.first { $0.kind == kind }
}
