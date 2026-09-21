import XCTest
@testable import IMCallKit

/// 多语言：文案表两种语言齐全、占位符一致、切换与覆盖的查找顺序、跟随系统的归类。
final class IMTextTests: XCTestCase {

    override func tearDown() {
        IMText.locale = .zhCN
        IMText.overrides = [:]
        super.tearDown()
    }

    func testBothLocalesHaveSameKeysAndNoEmptyValues() {
        XCTAssertEqual(Set(IMMessages.zhCN.keys), Set(IMMessages.en.keys))
        XCTAssertTrue((Array(IMMessages.zhCN.values) + Array(IMMessages.en.values)).allSatisfy { !$0.isEmpty })
    }

    func testPlaceholdersMatchAcrossLocales() throws {
        let hole = try NSRegularExpression(pattern: "\\{\\w+\\}")
        func holes(_ s: String) -> [String] {
            hole.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        for (key, zh) in IMMessages.zhCN {
            XCTAssertEqual(holes(zh), holes(IMMessages.en[key] ?? ""), key)
        }
    }

    func testDefaultChineseThenEnglishWithParams() {
        XCTAssertEqual(imT("end.busy"), "对方忙线中")
        IMText.locale = .en
        XCTAssertEqual(imT("end.busy"), "User is busy")
        XCTAssertEqual(imEndReasonText("hangup", role: "caller", durationSec: 65), "Call ended · 01:05")
    }

    func testOverrideWinsAndMissingKeyFallsBackToKey() {
        IMText.locale = .en
        IMText.overrides = [.en: ["ctl.accept": "Pick up"]]
        XCTAssertEqual(imT("ctl.accept"), "Pick up")
        XCTAssertEqual(imT("nope"), "nope")
    }

    func testConfigLocaleSyncsToText() {
        let config = IMCallKitConfig()
        config.locale = .en
        XCTAssertEqual(IMText.locale, .en)
    }

    func testSystemClassifiesByPrimaryLanguage() {
        XCTAssertEqual(IMLocale.system(languages: ["en-US"]), .en)
        XCTAssertEqual(IMLocale.system(languages: ["fr-FR", "en_GB"]), .en)
        XCTAssertEqual(IMLocale.system(languages: ["zh-Hant-TW"]), .zhCN)
        XCTAssertEqual(IMLocale.system(languages: ["ja"]), .zhCN)
    }
}
