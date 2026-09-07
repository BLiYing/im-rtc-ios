import Foundation
#if canImport(UIKit)
import UIKit
#endif
import XCTest
@testable import IMCallKit

/// 宿主身份解析（`IMProfileResolving`）。
///
/// 最要紧的一条是**同一个 uid 在不同解析器下显示不同的名字**——那正是备注的语义，
/// 也正是这份信息不能走服务端广播、必须由宿主本机解析的原因。
///
/// 这里测的是解析口径本身（纯逻辑），不碰视图——画得对不对属于真机验收。
final class ProfileResolverTests: XCTestCase {

    private final class FakeResolver: NSObject, IMProfileResolving {
        var names: [String: String?] = [:]
        func displayName(forUID uid: String) -> String? { names[uid] ?? nil }
        #if canImport(UIKit)
        var images: [String: UIImage] = [:]
        func avatarImage(forUID uid: String) -> UIImage? { images[uid] }
        #endif
    }

    func testNoResolverFallsBackToUID() {
        XCTAssertEqual(imResolvedName(nil, uid: "4820571639", fallback: "4820571639"), "4820571639")
    }

    func testResolvedNameWins() {
        let r = FakeResolver()
        r.names = ["4820571639": "明子"]
        XCTAssertEqual(imResolvedName(r, uid: "4820571639", fallback: "4820571639"), "明子")
    }

    /// 这一条是整件事的立足点：同一个 uid，两台设备两个名字（各自的备注）。
    /// 如果显示名走服务端广播，这个用例根本不可能通过。
    func testSameUIDDifferentNamesPerDevice() {
        let deviceA = FakeResolver(); deviceA.names = ["u1": "老张（欠我钱）"]
        let deviceB = FakeResolver(); deviceB.names = ["u1": "张经理"]
        XCTAssertEqual(imResolvedName(deviceA, uid: "u1", fallback: "u1"), "老张（欠我钱）")
        XCTAssertEqual(imResolvedName(deviceB, uid: "u1", fallback: "u1"), "张经理")
    }

    /// 「查到了但名字是空的」比「没查到」更糟：直接用会让格子上什么都没有。
    func testBlankNameFallsBack() {
        let r = FakeResolver()
        r.names = ["a": nil, "b": "", "c": "   ", "d": "\n"]
        for uid in ["a", "b", "c", "d"] {
            XCTAssertEqual(imResolvedName(r, uid: uid, fallback: uid), uid, "uid=\(uid) 没退回兜底")
        }
    }

    /// 本端那格 uid 是空串，label 就是「我」。去解析它既没意义，
    /// 也会让宿主收到一个莫名其妙的空 uid 查询。
    func testEmptyUIDIsNeverResolved() {
        let r = FakeResolver()
        r.names = ["": "不该被用到"]
        XCTAssertEqual(imResolvedName(r, uid: "", fallback: "我"), "我")
    }

    #if canImport(UIKit)
    func testAvatarPassesThroughUnchanged() {
        let r = FakeResolver()
        let photo = UIImage()
        r.images = ["u1": photo]
        XCTAssertTrue(imResolvedAvatar(r, uid: "u1") === photo, "Kit 不该对宿主给的图做任何加工")
        XCTAssertNil(imResolvedAvatar(r, uid: "u2"))
        XCTAssertNil(imResolvedAvatar(r, uid: ""), "空 uid 不解析")
    }
    #endif

    /// `avatarImage(forUID:)` 是 `@objc optional`：宿主只想改名字、不想管头像时
    /// 可以整个不实现。不实现不能崩，要当没有头像处理。
    func testOptionalAvatarMethodMayBeAbsent() {
        final class NameOnlyResolver: NSObject, IMProfileResolving {
            func displayName(forUID uid: String) -> String? { "只有名字" }
        }
        let r = NameOnlyResolver()
        XCTAssertEqual(imResolvedName(r, uid: "u1", fallback: "u1"), "只有名字")
        #if canImport(UIKit)
        XCTAssertNil(imResolvedAvatar(r, uid: "u1"))
        #endif
    }
}
