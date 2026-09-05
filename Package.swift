// swift-tools-version: 5.9
import PackageDescription

/*
 两个 product，一条硬边界：

   IMCallEngine   无 UI 的核心。**不依赖 libwebrtc、不 import UIKit**，
                  所以它能在 macOS 上直接 `swift test`——一致性向量、状态机、
                  帧编解码全都不需要模拟器。
   IMCallKit      整套通话界面（随后落地）。

 # 为什么把媒体实现挡在 Engine 之外

 libwebrtc 是个 iOS-only 的预编译二进制包，一旦被 Engine 直接依赖，
 「跑一次单测」就变成「起模拟器 + 下载几百 MB 二进制」。而本仓最需要频繁回归的
 恰恰是**不碰媒体的那一半**（协议编解码、三个状态机、四仓共用的一致性向量）。

 所以媒体只以 `MediaAdapter` 协议的形式出现在 Engine 里，真正的 libwebrtc 实现
 放在随后的 iOS-only target（`IMCallEngineWebRTC`）。这与 Web 端「engine 必须能在
 无 DOM 的 Node 里构造」是同一条约束，理由也一样。
 */
let package = Package(
    name: "im-rtc-ios",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        // **两个 product = 产品的两种集成方式。**
        // 只要 SDK、UI 自己画的宿主只依赖 IMCallEngine；要整套界面的加上 IMCallKit。
        .library(name: "IMCallEngine", targets: ["IMCallEngine"]),
        .library(name: "IMCallKit", targets: ["IMCallKit"])
    ],
    targets: [
        .target(name: "IMCallEngine"),
        // Kit 依赖 Engine，**绝不反向**（CONVENTIONS §1）。
        // 分成两个 target 而不是一个带 UI 的大 target：跨 module 的边界
        // 让「Kit 只能看见 Engine 的 public 面」每次编译都被检查一遍。
        .target(name: "IMCallKit", dependencies: ["IMCallEngine"]),
        .testTarget(name: "IMCallEngineTests", dependencies: ["IMCallEngine"])
    ]
)
