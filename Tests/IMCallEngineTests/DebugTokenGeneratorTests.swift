#if DEBUG
import XCTest

@testable import IMCallEngine

/// 调试密钥本地签票的一致性测试。向量在 server `docs/conformance/debug_token.json`，只读引用。
final class DebugTokenGeneratorTests: XCTestCase {
    private func vector() throws -> [String: Any] { try Vectors.load("debug_token.json") }

    func testHMACCases() throws {
        for c in try Vectors.array(try vector(), "hmac_cases") {
            let name = c["name"] as? String ?? "?"
            let sig = IMDebugTokenGenerator.sign(c["signing_input"] as! String, secret: c["secret"] as! String)
            XCTAssertEqual(sig, c["expect_signature"] as? String, name)
        }
    }

    func testSignCases() throws {
        for c in try Vectors.array(try vector(), "sign_cases") {
            let name = c["name"] as? String ?? "?"
            let input = c["input"] as! [String: Any]
            let secret = c["secret"] as! String
            let token = try IMDebugTokenGenerator.generate(
                appId: input["app_id"] as! String, keyId: c["key_id"] as! String, secret: secret,
                uid: input["uid"] as! String, deviceId: input["device_id"] as? String,
                ttlSec: input["ttl_sec"] as? Int,
                now: Date(timeIntervalSince1970: TimeInterval(c["now_unix"] as! Int)))
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.count, 3, name)
            XCTAssertFalse(token.contains("="), name)
            XCTAssertEqual(try decode(parts[0]) as NSDictionary, c["expect_header"] as! NSDictionary, name)
            XCTAssertEqual(try decode(parts[1]) as NSDictionary, c["expect_claims"] as! NSDictionary, name)
            XCTAssertEqual(IMDebugTokenGenerator.sign(parts[0] + "." + parts[1], secret: secret), parts[2], name)
        }
    }

    func testRejectCases() throws {
        for c in try Vectors.array(try vector(), "reject_cases") {
            let name = c["name"] as? String ?? "?"
            let input = c["input"] as! [String: Any]
            XCTAssertThrowsError(try IMDebugTokenGenerator.generate(
                appId: input["app_id"] as! String, keyId: c["key_id"] as? String ?? "dbg-1",
                secret: c["secret"] as? String ?? "0123456789abcdef", uid: input["uid"] as! String,
                deviceId: input["device_id"] as? String, ttlSec: input["ttl_sec"] as? Int), name) {
                XCTAssertEqual(($0 as? IMRTCError)?.code, .badParams, name)
            }
        }
    }

    private func decode(_ part: String) throws -> [String: Any] {
        var s = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: s))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
#endif
