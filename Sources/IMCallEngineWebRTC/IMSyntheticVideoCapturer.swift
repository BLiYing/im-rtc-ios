#if canImport(WebRTC) && canImport(UIKit)
import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import WebRTC

/**
 合成视频源：自己画帧推进 libwebrtc，**完全不碰摄像头**。

 # 为什么需要它

 **iOS 模拟器没有摄像头**（`RTCCameraVideoCapturer.captureDevices()` 恒为空），
 于是模拟器上的一切视频联调都只能看头像——九宫格版式、格子里的画面通没通、
 层上界选得对不对，一条都验不了，非得插真机。
 麦克风倒是有（模拟器转发宿主 Mac 的），所以**只有视频需要合成**：
 WebRTC 的 ObjC SDK 没有注入音频采样的公开口子，那要自己写 `AudioDeviceModule`（C++），
 而这里根本不需要。

 与 Web 端 `demo/src/syntheticMedia.ts` 是**同一套画面语言**：深色底 + 走动的秒针 +
 用户名 + 墙上时钟。**画面必须是活的**——静态图看不出「卡住了」和「通了」的区别，
 而这恰恰是要验的东西。

 # 用法

 它是个 `RTCVideoCapturer`，和 `RTCCameraVideoCapturer` 一样挂在 `RTCVideoSource` 上：

 ```swift
 let source = factory.videoSource()
 let capturer = IMSyntheticVideoCapturer(delegate: source, label: "alice")
 capturer.startCapture(width: 640, height: 480, fps: 15)
 ```

 **只给 Demo / 联调用**，不是产品能力：宿主真要「虚拟摄像头」应当自己实现
 `RTCVideoCapturer` 推自己的帧，这个类只是那条路的一个现成例子。
 */
public final class IMSyntheticVideoCapturer: RTCVideoCapturer {

    private let label: String
    private let queue = DispatchQueue(label: "im-rtc.synthetic-video")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    /// - Parameter label: 画在画面左上角的字（一般是自己的 uid），好在多端并排时认出是谁。
    public init(delegate: RTCVideoCapturerDelegate, label: String) {
        self.label = label
        super.init(delegate: delegate)
    }

    /**
     起采集。重复调用先停掉上一轮，**尺寸与帧率都可以中途换**。

     帧率**上限压到 15**：合成帧是 CPU 画出来的，模拟器上跑 30fps 只是白烧宿主机的电，
     而验版式与「画面是不是活的」15fps 绰绰有余。
     */
    public func startCapture(width: Int, height: Int, fps: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.width = max(2, width)
            self.height = max(2, height)
            self.pool = Self.makePool(width: self.width, height: self.height)
            let interval = 1.0 / Double(max(1, min(fps, 15)))
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    /// 停采集。**幂等**：没起过、或者已经停了，再调一次不出错。
    public func stopCapture() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        pool = nil
    }

    private func emitFrame() {
        guard let pool, let pixelBuffer = Self.makeBuffer(pool) else { return }
        draw(into: pixelBuffer)
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: buffer,
            rotation: ._0,
            timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000)
        )
        delegate?.capturer(self, didCapture: frame)
    }

    /// draw 把一帧画进 pixel buffer：深色底 + 走动的秒针 + 用户名 + 墙上时钟。
    private func draw(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                  data: base, width: width, height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setFillColor(UIColor(red: 0.07, green: 0.13, blue: 0.23, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 秒针：一秒一弧度，肉眼一看就知道画面是活的还是冻住的。
        let now = CACurrentMediaTime()
        let radius = min(w, h) * 0.3
        ctx.setStrokeColor(UIColor(red: 0.31, green: 0.82, blue: 0.77, alpha: 1).cgColor)
        ctx.setLineWidth(max(2, min(w, h) * 0.016))
        ctx.move(to: CGPoint(x: w / 2, y: h / 2))
        ctx.addLine(to: CGPoint(x: w / 2 + cos(now) * radius, y: h / 2 + sin(now) * radius))
        ctx.strokePath()

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let font = UIFont.systemFont(ofSize: max(12, h * 0.08), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let inset = h * 0.05
        label.draw(at: CGPoint(x: inset, y: inset), withAttributes: attrs)
        Self.clockFormatter.string(from: Date())
            .draw(at: CGPoint(x: inset, y: h - inset - font.lineHeight), withAttributes: attrs)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 走 pool 而不是每帧新建：每帧 `CVPixelBufferCreate` 在模拟器上就是稳定的一串卡顿。
    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        return pool
    }

    private static func makeBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}
#endif
