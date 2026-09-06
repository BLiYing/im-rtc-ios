import Foundation

/*
 权限申请的决策逻辑（交互稿 §01–§02）：**前置说明卡 → 系统框 → 结果分支**，三段式。

 说明卡不是每次都出：
 · 未决定（首次）：先出说明卡再问系统——系统框只有一次机会，说明卡是为它做铺垫；
 · 已授权：一个框都不出，直接开始；
 · 已拒绝：系统框不会再出现，直接进「被拒」分支（去设置）。

 系统状态由 `IMDevicePermissionProbe` 提供（默认走 AVFoundation，见 IMCallController+Permissions），
 测试注入假的。这里只有决策，没有 UIKit——所以能在 macOS 上测。
 与 Web 的 `state/permissions.ts` 是同一套分支。
 */

/// 要申请的设备。
public enum IMDeviceKind: String, Sendable {
    case microphone, camera
}

/// 系统的权限状态。
public enum IMPermissionStatus: Sendable {
    case granted, denied, notDetermined
}

/// 探测失败的两种结局。
public enum IMPermissionFailure: Sendable {
    case denied, noDevice
}

/// 系统权限的读与问。可注入：测试里不需要真设备。
public protocol IMDevicePermissionProbe: AnyObject, Sendable {
    func status(of kind: IMDeviceKind) -> IMPermissionStatus
    /// 弹系统框；已授权 / 已拒绝时不弹，直接回当前结果。
    func request(_ kind: IMDeviceKind) async -> Bool
}

/// `ensure` 的四种结局。
public enum IMPermissionOutcome: Equatable, Sendable {
    case ok
    /// 摄像头拿不到：**通话继续，只是没画面**。
    case cameraBlocked
    /// 麦克风拿不到：**整通话取消**，不发 invite / accept。
    case micBlocked
    /// 用户在说明卡上点了「取消」。
    case cancelled
}

/// imPermissionDevices 决定一次动作要申请哪些设备（交互稿 §01 的表）。
/// 麦克风先问：它被拒了整通话都不成立，没必要再问摄像头。
public func imPermissionDevices(mediaType: String, withCamera: Bool) -> [IMDeviceKind] {
    mediaType == "video" && withCamera ? [.microphone, .camera] : [.microphone]
}

/// imNeedsPermissionExplanation：只有「首次」才出我们自己的说明卡。
public func imNeedsPermissionExplanation(_ status: IMPermissionStatus) -> Bool {
    status == .notDetermined
}

/// 说明卡 / 被拒卡的文案（规范 §08）。
public struct IMPermissionCopy: Equatable, Sendable {
    public let title: String
    public let body: String
}

/// imPermissionExplanation：说清**用来做什么**，不说「请授权」。
public func imPermissionExplanation(_ kind: IMDeviceKind) -> IMPermissionCopy {
    switch kind {
    case .microphone:
        return IMPermissionCopy(title: "需要用到麦克风",
                                body: "通话时对方要听见你的声音。接下来系统会问你要不要允许。")
    case .camera:
        return IMPermissionCopy(title: "需要用到摄像头",
                                body: "视频通话时对方要看见你。接下来系统会问你要不要允许。")
    }
}

/// imPermissionBlocked：麦克风走不下去；摄像头降级为语音继续。
public func imPermissionBlocked(_ kind: IMDeviceKind, _ failure: IMPermissionFailure) -> IMPermissionCopy {
    switch (kind, failure) {
    case (.camera, .denied):
        return IMPermissionCopy(title: "没有摄像头权限，已用语音继续通话",
                                body: "要开视频，请到系统设置里打开摄像头权限。")
    case (.camera, .noDevice):
        return IMPermissionCopy(title: "找不到可用的摄像头，已用语音继续通话",
                                body: "摄像头可能被其他应用占用。")
    case (.microphone, .denied):
        return IMPermissionCopy(title: "没有麦克风权限，无法通话",
                                body: "到「设置 › 隐私 › 麦克风」里打开后重试。")
    case (.microphone, .noDevice):
        return IMPermissionCopy(title: "找不到可用的麦克风",
                                body: "请检查麦克风是否被其他应用占用。")
    }
}

/**
 一张要画的卡：说明卡有「取消 / 好」两个动作，被拒卡只有「知道了」（麦克风被拒时多一个「去设置」）。
 `IMCallWindow` 负责画，点了哪个由 `answer` 回传。
 */
public struct IMPromptCard: Sendable {
    public enum Kind: Sendable { case explain, blocked }
    public let kind: Kind
    public let device: IMDeviceKind
    public let title: String
    public let body: String
    public let primaryLabel: String
    /// 空串 = 没有次要动作。
    public let secondaryLabel: String
    /// 是否给「去设置」（iOS 上能直接跳系统设置，Web 上跳不了）。
    public let offersSettings: Bool
    /// 用户点了哪个：true = 主动作。
    public let answer: @Sendable (Bool) -> Void

    /// withAnswer 换掉回答闭包——gate 造卡时还不知道谁来收答案，由画卡的那一层补上。
    public func withAnswer(_ answer: @escaping @Sendable (Bool) -> Void) -> IMPromptCard {
        IMPromptCard(kind: kind, device: device, title: title, body: body, primaryLabel: primaryLabel,
                     secondaryLabel: secondaryLabel, offersSettings: offersSettings, answer: answer)
    }
}

/**
 IMPermissionGate 把三段式串起来。

 `present` 是「出一张卡并等用户点」；`probe` 是真的去拿设备（Engine 的 `probeMicrophone` /
 `startLocalPreview`），它抛的 2001 / 2002 决定分支。**系统状态查询只用来决定要不要出说明卡，
 判失败一律靠真探**——Web 端在合成媒体源上撞过「查询说被拒、其实拿得到」。
 */
public final class IMPermissionGate: @unchecked Sendable {
    public typealias Present = @Sendable (IMPromptCard) async -> Bool
    public typealias Probe = @Sendable (IMDeviceKind) async throws -> Void
    public typealias Classify = @Sendable (Error) -> IMPermissionFailure?

    private let systemProbe: IMDevicePermissionProbe
    private let present: Present
    private let probe: Probe
    private let classify: Classify

    public init(systemProbe: IMDevicePermissionProbe, present: @escaping Present,
                probe: @escaping Probe, classify: @escaping Classify) {
        self.systemProbe = systemProbe
        self.present = present
        self.probe = probe
        self.classify = classify
    }

    /// ensure 按顺序探每个设备，返回该怎么继续。
    public func ensure(_ devices: [IMDeviceKind]) async -> IMPermissionOutcome {
        var outcome: IMPermissionOutcome = .ok
        for kind in devices {
            if imNeedsPermissionExplanation(systemProbe.status(of: kind)) {
                let copy = imPermissionExplanation(kind)
                let go = await present(card(.explain, kind, copy, primary: "好", secondary: "取消"))
                if !go { return .cancelled }
            }
            let failure: IMPermissionFailure?
            do {
                try await probe(kind)
                failure = nil
            } catch {
                guard let known = classify(error) else { continue } // 不是权限问题：不吞，也不当被拒
                failure = known
            }
            guard let failure else { continue }
            let copy = imPermissionBlocked(kind, failure)
            _ = await present(card(.blocked, kind, copy, primary: "知道了", secondary: ""))
            if kind == .microphone { return .micBlocked }
            outcome = .cameraBlocked
        }
        return outcome
    }

    private func card(_ kind: IMPromptCard.Kind, _ device: IMDeviceKind, _ copy: IMPermissionCopy,
                      primary: String, secondary: String) -> IMPromptCard {
        IMPromptCard(kind: kind, device: device, title: copy.title, body: copy.body,
                     primaryLabel: primary, secondaryLabel: secondary,
                     offersSettings: kind == .blocked, answer: { _ in })
    }
}
