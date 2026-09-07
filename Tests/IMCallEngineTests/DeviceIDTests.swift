import XCTest
@testable import IMCallEngine

/// `device_id` 的入参校验（协议 §2.5）。
///
/// 这一层的价值不是「多一道防线」，而是**把服务端那句话送到宿主手里**：
/// 不拦的话服务端回 1004，宿主只看到 `bad_params`，界面上是「登录失败」四个字。
final class DeviceIDTests: XCTestCase {

    /// reason 取出 detail 里那句人话；顺带断言码是 1004。
    private func reason(_ deviceID: String) -> String {
        do {
            try IMDeviceID.check(deviceID)
            return "没有抛"
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .badParams, "本地拦下的和服务端拒的该是同一个码")
            return error.detail
        } catch {
            return "不是 IMRTCError: \(error)"
        }
    }

    func testAcceptsLegalIDs() throws {
        for id in ["web1",
                   "3f2b8c1a-9d4e-4f77-8a21-0b5c6d7e8f90", // identifierForVendor 就长这样
                   "iphone_15_pro",
                   String(repeating: "a", count: 64)] {
            XCTAssertNoThrow(try IMDeviceID.check(id), "\(id) 该放行")
        }
    }

    func testRejectsEmpty() {
        XCTAssertTrue(reason("").contains("不能为空"))
    }

    func testRejectsTooLongAndSaysHowLong() {
        let msg = reason(String(repeating: "a", count: 65))
        XCTAssertTrue(msg.contains("65 字节"), msg)
        XCTAssertTrue(msg.contains("64"), msg)
    }

    /// 按**字节**算，不按字符——按字符算的话 22 个汉字（66 字节）会漏过去。
    func testCountsBytesNotCharacters() {
        XCTAssertTrue(reason(String(repeating: "设", count: 22)).contains("66 字节"))
    }

    /// 报出到底是哪个字符——这就是 Pixel 2 XL 那个 bug 查了一轮才定位到的东西。
    func testRejectsSpaceAndNamesTheOffendingCharacter() {
        let msg = reason("Pixel 2 XL")
        XCTAssertTrue(msg.contains("' '"), msg)
        XCTAssertTrue(msg.contains("[A-Za-z0-9_-]"), msg)
    }

    func testRejectsOtherIllegalCharsets() {
        // 「张三的 iPhone」是 UIDevice.current.name 的默认形态，两条规则一起犯。
        for id in ["张三的 iPhone", "moto g(7) power", "web.1", "Mozilla/5.0", "mac:01"] {
            XCTAssertTrue(reason(id).contains("[A-Za-z0-9_-]"), "\(id) 该被拦下")
        }
    }

    /// 光有校验函数不算数——**它得真的挂在 login 的路径上**。
    ///
    /// 少了这条断言，`IMDeviceID` 可以是一个从没人调用的完美函数。
    func testLoginRejectsBadDeviceIDBeforeOpeningSocket() async {
        let box = SocketBox()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!,
                                  deviceID: "Pixel 2 XL", media: nil)
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }

        // **必须限时**：校验一旦失灵，login 会去等一条永不 open 的假 socket，
        // 于是这条用例不是变红而是**挂死**——注入 bug 验证时踩到过，
        // xctest 一声不吭地悬在那里。挂死是最糟的红：CI 上看不出是断言失败还是环境卡了。
        let done = expectation(description: "login 返回（无论成败）")
        Task {
            do {
                try await engine.login("test-token")
                XCTFail("device_id 不合规，login 本该失败")
            } catch let error as IMRTCError {
                XCTAssertEqual(error.code, .badParams)
            } catch {
                XCTFail("抛的不是 IMRTCError: \(error)")
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2.0)
        XCTAssertEqual(box.count, 0, "拦下之后不该开任何连接")
    }

    /// 上限是**公开常量**，宿主要拿它裁自己生成的 id。
    ///
    /// 不给常量，宿主就会把 64 抄进自己代码里，协议改了两边对不上。
    func testMaxBytesIsPublicAndMatchesProtocol() {
        XCTAssertEqual(IMDeviceID.maxBytes, 64)
        XCTAssertNoThrow(try IMDeviceID.check(String(repeating: "a", count: IMDeviceID.maxBytes)))
        XCTAssertThrowsError(try IMDeviceID.check(String(repeating: "a", count: IMDeviceID.maxBytes + 1)))
    }

    /// **ObjC 宿主视角**：`login:completionHandler:` 里拿到的 `NSError` 要能用。
    ///
    /// 首批宿主 IMProgram 是 ObjC 工程，`error.code == 1004` 是它唯一的分支依据。
    /// 少了这条断言，Swift 侧全绿而 ObjC 侧拿到的还是 domain=`IMCallEngine.IMRTCError`、
    /// code=1、detail 丢光——正好是这层校验要消灭的「登录失败，没有下文」。
    func testLoginErrorIsUsableFromObjC() async {
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!,
                                  deviceID: "张三的 iPhone", media: nil)
        engine.webSocketFactory = { _ in FakeWebSocket() }

        do {
            try await engine.login("test-token")
            XCTFail("device_id 不合规，login 本该失败")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, IMRTCErrorDomain, "ObjC 宿主靠 domain 认这是不是我们的错误")
            XCTAssertEqual(ns.code, 1004, "ObjC 宿主靠 code 分支；1 说明桥接没生效")
            XCTAssertEqual(ns.userInfo[IMRTCErrorNameKey] as? String, "bad_params")
            XCTAssertTrue(ns.localizedDescription.contains("[A-Za-z0-9_-]"),
                          "服务端那句话要送到宿主手里，实际是：\(ns.localizedDescription)")
        }
    }
}

