import Foundation

/*
 「这一格该裁切填满，还是等比留黑边」——纯几何判据。

 规则与真机依据见 `im-rtc-server/docs/mechanism/VIDEO_RENDERING.md`（五仓统一）：

     裁切填充后画面还剩 ≥ 56.25% 可见  →  FILL（裁一点，换来没有黑边）
     剩 < 56.25%                      →  FIT （宁可留黑边，也不要放大 + 砍掉大半）

 # 为什么是几何判据，不是「看版式」

 `IMCallKit` 只依赖 `IMCallEngine`、**够不到 libwebrtc 的渲染视图**，
 传不了「此刻是九宫格还是全屏」这种 UI 概念。而只要「格子宽高」与「源宽高」
 两个数就够算——以后加画中画、共享屏幕、横屏，都不用回来改这里。

 # 为什么放在 Engine 而不是 WebRTC 那一层

 与 `IMVideoProfile` 同一条理由：这是纯算术，放在 Engine 里 **macOS 上
 `swift test` 就能跑**，不必为了测一个比大小去起模拟器。
 判据本身最容易写错（宽高比取反、比较方向），而它错了之后症状是「画面糊」
 或「莫名黑边」，**没有任何报错**。

 # 与 Android 的一处差别，不是漂

 iOS 的 `RTCVideoViewDelegate.videoView(_:didChangeVideoSize:)` 给的是**已经旋转过**
 的显示尺寸，所以这里不收旋转角；Android 的 `onFrameResolutionChanged` 给的是
 未旋转的缓冲区尺寸 + 旋转角，那边的 `IMVideoFit` 多一个参数并自己换算。
 **判据本身是同一个**，只是各平台回调的契约不同。
 */

/// 可见比例的下限，**9/16 = 0.5625**。
///
/// 不是凑的：它正好让**竖屏源（9:16）填满正方形格子**落在边界上——
/// 那一格裁掉 44% 的高、而且是缩小，不会糊，所以该填满；
/// 再严一点就会让九宫格白留两条宽黑边。
/// 与 libwebrtc `RendererCommon.BALANCED_VISIBLE_FRACTION` 同值。
public let imMinVisibleFraction: Double = 0.5625

/// imVisibleFraction 算「裁切填满之后源画面还剩多少比例可见」。
/// 任一边为 0（尺寸还没量出来）时返回 `0`。
public func imVisibleFraction(
    videoWidth: Double, videoHeight: Double, viewWidth: Double, viewHeight: Double
) -> Double {
    guard videoWidth > 0, videoHeight > 0, viewWidth > 0, viewHeight > 0 else { return 0 }
    let sourceAspect = videoWidth / videoHeight
    let viewAspect = viewWidth / viewHeight
    // 裁切时按较「紧」的那一边缩放，另一边溢出被裁掉；剩下的比例就是两个宽高比之商。
    return min(sourceAspect, viewAspect) / max(sourceAspect, viewAspect)
}

/// imShouldFillVideo 判断该不该裁切填满。
///
/// **尺寸还没量出来时返回 `true`** —— 先填满总比先露一圈黑边好看，
/// 等尺寸到了会再算一次。
public func imShouldFillVideo(
    videoWidth: Double, videoHeight: Double, viewWidth: Double, viewHeight: Double
) -> Bool {
    let fraction = imVisibleFraction(
        videoWidth: videoWidth, videoHeight: videoHeight,
        viewWidth: viewWidth, viewHeight: viewHeight)
    return fraction == 0 || fraction >= imMinVisibleFraction
}
