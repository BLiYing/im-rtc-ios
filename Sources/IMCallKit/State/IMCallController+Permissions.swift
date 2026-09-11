import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import IMCallEngine

/*
 权限门的接线（决策逻辑在 IMPermissionGate.swift，纯函数、有单测）。

 三件事在这里：系统权限的读与问（AVFoundation）、把 Engine 抛的错归类、把「出一张卡并等用户点」
 接到 `promptCard` 上——IMCallWindow 画卡，用户点了哪个经 `answer` 回来，continuation 才继续。
 */

/// 默认的系统探针：走 AVFoundation。macOS 上 `swift test` 用不到它（Kit 的界面用例注入假的）。
final class IMSystemPermissionProbe: IMDevicePermissionProbe, @unchecked Sendable {
    func status(of kind: IMDeviceKind) -> IMPermissionStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: media(kind)) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
        #else
        return .granted
        #endif
    }

    func request(_ kind: IMDeviceKind) async -> Bool {
        #if canImport(AVFoundation)
        return await AVCaptureDevice.requestAccess(for: media(kind))
        #else
        return true
        #endif
    }

    #if canImport(AVFoundation)
    private func media(_ kind: IMDeviceKind) -> AVMediaType { kind == .camera ? .video : .audio }
    #endif
}

/// classifyPermissionError 把 Engine 抛的 2001 / 2002 归成被拒 / 无设备；别的错误不是权限问题。
func classifyPermissionError(_ error: Error) -> IMPermissionFailure? {
    guard let rtc = error as? IMRTCError else { return nil }
    switch rtc.code {
    case .devicePermissionDenied: return .denied
    case .deviceNotFound: return .noDevice
    default: return nil
    }
}

extension IMCallController {
    /// makePermissionGate 造权限门。`systemProbe` 可注入（测试用假的）。
    func makePermissionGate(systemProbe: IMDevicePermissionProbe) -> IMPermissionGate {
        IMPermissionGate(
            systemProbe: systemProbe,
            present: { [weak self] card in
                guard let self else { return false }
                return await self.present(card)
            },
            probe: { [weak self] kind in
                guard let self else { return }
                try await self.probeDevice(kind, systemProbe: systemProbe)
            },
            classify: { classifyPermissionError($0) })
    }

    /// present 出一张卡并等用户点。卡由 IMCallWindow 画；这里只管把答案接回 continuation。
    private func present(_ card: IMPromptCard) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answered = IMOnce()
            let shown = card.withAnswer { [weak self] ok in
                guard answered.take() else { return }
                Task { @MainActor in
                    self?.showPrompt(nil)
                    continuation.resume(returning: ok)
                }
            }
            Task { @MainActor in self.showPrompt(shown) }
        }
    }

    /**
     probeDevice 真的去问一次。**摄像头只问权限、不开摄像头。**

     原先摄像头拿 `startLocalPreview` 探，探完还 `setCamera(true)`：群通话默认关摄像头进来，
     过一遍权限门按钮就被点亮、摄像头也真开着——等于替用户开了摄像头。
     开不开由 `startPreviewIfWanted` 看 `cameraOn` 决定。
     */
    private func probeDevice(_ kind: IMDeviceKind, systemProbe: IMDevicePermissionProbe) async throws {
        switch kind {
        case .microphone:
            try await engine.probeMicrophone()
        case .camera:
            guard cameraCID.isEmpty else { return } // 已经在采集，权限早就有了
            guard await systemProbe.request(.camera) else {
                throw IMRTCError(.devicePermissionDenied, "摄像头权限被拒")
            }
        }
    }

    /// startPreviewIfWanted：权限门放行之后，**本端摄像头开着才起预览**（草图 §03-E：接通前看得见自己）。
    func startPreviewIfWanted() async {
        let wanted = await MainActor.run {
            self.state.mediaType == "video" && self.state.selfState.cameraOn && !self.state.selfState.cameraBlocked
        }
        guard wanted, cameraCID.isEmpty else { return }
        do {
            cameraCID = try await engine.startLocalPreview()
            // cid 不在 state 里，状态相等时 didSet 不会通知——本端预览要靠这一下才挂得上。
            await MainActor.run { self.broadcast() }
        } catch {
            // 权限门刚放行过，这里再失败多半是设备被占：按钮变禁用，通话照打。
            IMRTCLog.warn("[Kit] 本端预览起不来", ["err": String(describing: error)])
            if classifyPermissionError(error) != nil { await MainActor.run { self.apply(.cameraBlocked) } }
        }
    }
}

/// IMOnce 保证 continuation 只被 resume 一次——用户连点两下「好」不能炸。
private final class IMOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
