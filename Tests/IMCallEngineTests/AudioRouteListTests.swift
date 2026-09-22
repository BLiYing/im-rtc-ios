import XCTest
@testable import IMCallEngine

/// 路由清单与「此刻在用哪条」的纯逻辑（设计稿 §04 面板的数据源）。**不需要模拟器**。
final class AudioRouteListTests: XCTestCase {

    private func build(_ inputs: [(type: String, name: String, uid: String)]) -> [IMAudioRoute] {
        imBuildAudioRoutes(inputs: inputs)
    }

    func testBuiltInTwoAlwaysThere() {
        let routes = build([("MicrophoneBuiltIn", "iPhone 麦克风", "builtin-mic")])
        XCTAssertEqual(routes.map(\.kind), [.earpiece, .speaker], "内置麦克风不产生第三条路由")
        XCTAssertEqual(routes.map(\.name), ["", ""], "内置两条不带设备名，文案由 Kit 本地化")
        XCTAssertEqual(routes.map(\.uid), [imAudioRouteEarpieceUID, imAudioRouteSpeakerUID])
    }

    func testWiredHeadsetAppendsThird() {
        let routes = build([("MicrophoneBuiltIn", "iPhone 麦克风", "builtin-mic"),
                            ("HeadsetMicrophone", "有线耳机", "wired-1")])
        XCTAssertEqual(routes.map(\.kind), [.earpiece, .speaker, .wiredHeadset])
        XCTAssertEqual(routes.last?.name, "有线耳机", "外接设备要带系统给的名字")
        XCTAssertEqual(routes.last?.uid, "wired-1")
    }

    func testUSBCountsAsWired() {
        let routes = build([("USBAudio", "USB-C 耳机", "usb-1")])
        XCTAssertEqual(routes.map(\.kind), [.earpiece, .speaker, .wiredHeadset], "转接头耳机归有线那一类")
    }

    func testBluetoothAppendsWithName() {
        let routes = build([("MicrophoneBuiltIn", "iPhone 麦克风", "builtin-mic"),
                            ("BluetoothHFP", "AirPods Pro", "bt-1")])
        XCTAssertEqual(routes.map(\.kind), [.earpiece, .speaker, .bluetooth])
        XCTAssertEqual(routes.last?.name, "AirPods Pro", "面板那一行要写 AirPods，不是「蓝牙」")
    }

    func testOrderIsEarpieceSpeakerWiredBluetooth() {
        // 故意把蓝牙放在有线前面进来，出来的顺序仍要与设计稿面板行序一致。
        let routes = build([("BluetoothHFP", "AirPods", "bt-1"),
                            ("HeadsetMicrophone", "有线耳机", "wired-1")])
        XCTAssertEqual(routes.map(\.kind), [.earpiece, .speaker, .wiredHeadset, .bluetooth])
    }

    func testCurrentKindByOutputPort() {
        XCTAssertEqual(imCurrentAudioRouteKind(outputPorts: ["Receiver"]), .earpiece)
        XCTAssertEqual(imCurrentAudioRouteKind(outputPorts: ["Speaker"]), .speaker)
        XCTAssertEqual(imCurrentAudioRouteKind(outputPorts: ["Headphones"]), .wiredHeadset)
        XCTAssertEqual(imCurrentAudioRouteKind(outputPorts: ["BluetoothHFP"]), .bluetooth)
        XCTAssertEqual(imCurrentAudioRouteKind(outputPorts: ["BluetoothA2DPOutput"]), .bluetooth,
                       "A2DP 也算蓝牙：通话里不该出现，但真出现了要认得出来")
        XCTAssertEqual(imCurrentAudioRouteKind(outputPorts: []), .earpiece, "认不出来回落听筒，不回落静音")
    }

    func testPickCurrentMatchesByKind() {
        let routes = build([("BluetoothHFP", "AirPods", "bt-1")])
        XCTAssertEqual(imPickCurrentRoute(routes: routes, outputPorts: ["BluetoothHFP"])?.uid, "bt-1")
        XCTAssertEqual(imPickCurrentRoute(routes: routes, outputPorts: ["Speaker"])?.uid, imAudioRouteSpeakerUID)
        // 强制外放时输出是 Speaker、输入仍是蓝牙麦：按输出判，勾要打在「扬声器」上。
        XCTAssertEqual(imPickCurrentRoute(routes: routes, outputPorts: ["Speaker"])?.kind, .speaker)
    }

    func testPickReturnsNilWhenKindAbsent() {
        let routes = build([])
        XCTAssertNil(imPickCurrentRoute(routes: routes, outputPorts: ["BluetoothHFP"]),
                     "清单里没有蓝牙就不打勾，别打错")
    }

    func testEqualityByUID() {
        let a = IMAudioRoute(kind: .bluetooth, name: "AirPods", uid: "bt-1")
        let b = IMAudioRoute(kind: .bluetooth, name: "改了个名", uid: "bt-1")
        XCTAssertEqual(a, b, "同一个设备改了显示名仍是同一条路由")
        XCTAssertNotEqual(a, IMAudioRoute(kind: .bluetooth, name: "AirPods", uid: "bt-2"))
    }

    /// **接了两只同类设备时，`imPickCurrentRoute` 按 `kind` 认，分不出哪一只在用**——
    /// `inputPort(for:)` 的注释里写过这个已知限制（按类型分不出是哪一只蓝牙），这里把它钉成用例：
    /// 清单两条都在，勾会落在遍历到的第一条上，不代表那一条真的在用。别指望这个函数能分辨。
    func testPickCurrentIsAmbiguousWithTwoOfSameKind() {
        let routes = build([("BluetoothHFP", "车载", "bt-car"), ("BluetoothHFP", "AirPods", "bt-airpods")])
        XCTAssertEqual(routes.filter { $0.kind == .bluetooth }.count, 2, "两只蓝牙都要出现在清单里")
        XCTAssertEqual(imPickCurrentRoute(routes: routes, outputPorts: ["BluetoothHFP"])?.uid, "bt-car",
                       "按 kind 认，只会落在清单里第一条同类路由上——即使实际在用的是 AirPods")
    }
}
