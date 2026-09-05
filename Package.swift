// swift-tools-version: 5.9
import PackageDescription

/*
 两个 product，一条硬边界：

   IMCallEngine   无 UI 的核心。**不依赖 libwebrtc、不 import UIKit**，
                  所以它能在 macOS 上直接 `swift test`——一致性向量、状态机、
                  帧编解码全都不需要模拟器。
   IMCallKit      整套通话界面（随后落地）。

 # 为什么把媒体实现挡在 Engine 之外

 libwebrtc 是个预编译二进制包，一旦被 Engine 直接依赖，「跑一次单测」就得
 连着媒体栈一起编。而本仓最需要频繁回归的恰恰是**不碰媒体的那一半**
 （协议编解码、三个状态机、四仓共用的一致性向量）。

 所以媒体只以 `IMMediaAdapter` 协议的形式出现在 Engine 里，真正的 libwebrtc 实现
 放在 iOS-only 的 `IMCallEngineWebRTC`。这与 Web 端「engine 必须能在无 DOM 的
 Node 里构造」是同一条约束，理由也一样。

 # 但要如实说清一件事：依赖仍然会被下载

 SwiftPM **解析阶段就会拉取二进制产物**，不管你构建哪个 target。
 实测代价（2026-09-05，M152）：**43 MB**，首次解析 + 构建约 40 秒；
 之后产物缓存在 `~/Library/Caches/org.swift.swiftpm`，增量构建 0.9 秒、
 `swift test` 12 秒不变。比"几百 MB"小得多——这个数是量过的，不是估的。

 真正被保住的是**代码层面的边界**：`IMCallEngine` 不 import WebRTC，
 所以它在没有媒体的环境里照样能构造、能跑全部状态机与向量用例。
 这条才是可测性与「将来换媒体实现」的根据。

 没有用 SwiftPM 的 traits（Swift 6.1 起可条件化依赖）：那要把 tools-version
 抬到 6.1，等于抬高每一个第三方宿主的最低 Xcode 版本——对一个要发给别人的
 SDK 来说，这个代价比一次下载高得多。

 # 三个 product = 三种集成方式

   IMCallEngine        只要信令与回调，UI 自己画（**不下载 libwebrtc 也能用**）
   IMCallKit           要整套通话界面
   IMCallEngineWebRTC  要真的能出声出画（iOS-only）
 */
let package = Package(
    name: "im-rtc-ios",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "IMCallEngine", targets: ["IMCallEngine"]),
        .library(name: "IMCallKit", targets: ["IMCallKit"]),
        .library(name: "IMCallEngineWebRTC", targets: ["IMCallEngineWebRTC"])
    ],
    dependencies: [
        /*
         **版本 exact 锁死，不用 from:**。libwebrtc 的预编译包跟着 Chromium
         里程碑走，小版本之间也可能动 ObjC API；让它自动升级等于把一个
         我们控制不了的变更引入到媒体面。升级是一次有意的动作，配一次真机回归。

         Google 从 M80 起不再发布官方的移动端预编译产物，所以这类第三方打包
         是目前唯一现实的选择（自己从源码编要 depot_tools + 几十 GB + 几小时）。
         */
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "152.0.0")
    ],
    targets: [
        .target(name: "IMCallEngine"),
        // Kit 依赖 Engine，**绝不反向**（CONVENTIONS §1）。
        // 分成两个 target 而不是一个带 UI 的大 target：跨 module 的边界
        // 让「Kit 只能看见 Engine 的 public 面」每次编译都被检查一遍。
        .target(name: "IMCallKit", dependencies: ["IMCallEngine"]),
        /*
         媒体实现。**iOS-only**：libwebrtc 的 ObjC API 与渲染视图都只在 iOS 上有，
         整个 target 的源码包在 `#if canImport(UIKit) && canImport(WebRTC)` 里，
         所以 macOS 上 `swift build` 编出来是个空模块，不会挡住单测。
         */
        .target(name: "IMCallEngineWebRTC",
                dependencies: ["IMCallEngine", .product(name: "WebRTC", package: "WebRTC")]),
        .testTarget(name: "IMCallEngineTests", dependencies: ["IMCallEngine"]),
        .testTarget(name: "IMCallKitTests", dependencies: ["IMCallKit"])
    ]
)
