#if canImport(WebRTC) && canImport(UIKit)
import AVFoundation
import Foundation
import WebRTC
import IMCallEngine

/*
 `IMWebRTCAdapter` 里**不碰可变状态**的那几件事：权限、挑采集格式、音频会话、simulcast 编码参数。

 拆出来是因为主文件逼近 600 行红线。这里全是 static 或只读入参，不需要进锁——
 加锁的字段一个都不许挪到这里来。
 */

/// 一次摄像头采集用哪个设备、哪个格式、多少帧。
struct IMCaptureChoice {
    let device: AVCaptureDevice
    let format: AVCaptureDevice.Format
    let fps: Int
}

extension IMWebRTCAdapter {

    /// ensureAccess 把系统权限状态收敛成结构化错误：拒绝 → 2001。
    static func ensureAccess(_ media: AVMediaType, what: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
            return
        case .notDetermined:
            // 这一步会弹系统框，只弹一次；之后系统记住选择。
            guard await AVCaptureDevice.requestAccess(for: media) else {
                throw IMRTCError(.devicePermissionDenied, "\(what)权限被拒")
            }
        default:
            throw IMRTCError(.devicePermissionDenied, "\(what)权限被拒")
        }
    }

    /// captureChoice 挑**指定朝向 + 最接近档位分辨率**的格式。
    ///
    /// 挑「最接近」而不是「必须等于」：设备支持的格式表是离散的，
    /// 要求精确匹配会在某些机型上一个格式都挑不出来，通话直接打不出去。
    static func captureChoice(front: Bool, profile: IMVideoProfile) throws -> IMCaptureChoice {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let wantedPosition: AVCaptureDevice.Position = front ? .front : .back
        guard let device = devices.first(where: { $0.position == wantedPosition }) ?? devices.first else {
            throw IMRTCError(.deviceNotFound, "没有可用的摄像头")
        }
        let wanted = profile.width
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(l.width) - wanted) < abs(Int(r.width) - wanted)
        }) else {
            throw IMRTCError(.deviceNotFound, "摄像头没有可用格式")
        }
        let fps = format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max().map { Int(min($0, Double(profile.frameRate))) }
            ?? profile.frameRate
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        IMRTCLog.info("摄像头已开", [
            "profile": profile.name, "width": String(size.width),
            "height": String(size.height), "fps": String(fps),
        ])
        return IMCaptureChoice(device: device, format: format, fps: fps)
    }

    /**
     halt 停采集。**特意是个同步函数**：`RTCCameraVideoCapturer` 同时有同步的 `stopCapture()`
     和带回调的那个（Swift 会把后者导成 async），在 async 函数里直接写 `stopCapture()`
     编译器挑的是 async 那个，于是要求 await。放进同步函数里就不会挑错。
     */
    static func halt(_ camera: RTCCameraVideoCapturer?, _ synthetic: IMSyntheticVideoCapturer?) {
        camera?.stopCapture()
        synthetic?.stopCapture()
    }

    /**
     configureAudioSession 配音频会话。

     `.voiceChat` 模式会打开**回声消除与自动增益**——不配的话自己会听到自己的回声，
     而那听起来像"对方设备有问题"，很容易查错方向。
     */
    func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            // 配不上不该让通话直接失败：多数情况下仍能出声，只是路由不理想。
            IMRTCLog.warn("音频会话配置失败", ["err": String(describing: error)])
        }
    }

    /// simulcastEncodings 是 simulcast 三层（协议 §3.5：rid 为 h/m/l），码率跟着档位走。
    static func simulcastEncodings(_ profile: IMVideoProfile) -> [RTCRtpEncodingParameters] {
        profile.simulcastLayers.map { layer in
            let encoding = RTCRtpEncodingParameters()
            encoding.rid = layer.rid
            encoding.isActive = true
            encoding.scaleResolutionDownBy = NSNumber(value: layer.scaleDownBy)
            encoding.maxBitrateBps = NSNumber(value: layer.bitrateBps)
            return encoding
        }
    }

    static func stateName(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }
}
#endif
