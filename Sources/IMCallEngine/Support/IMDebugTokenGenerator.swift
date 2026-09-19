#if DEBUG
import CryptoKit
import Foundation

/*
 调试密钥本地签票（server `docs/design/DEBUG_KEY_DESIGN.md` §4）。

 **仅联调用**：没有后台、拿不到 `POST /v1/tokens` 时，用控制台发的调试密钥（kid 以 `dbg-` 开头）
 在本机签一张 HS256 票。整个类型包在 `#if DEBUG` 里，Release 构建里不存在——
 上线必须换成后端换票。每次调用都会打一条 warn。

 一致性向量：`im-rtc-server/docs/conformance/debug_token.json`（`IMDebugTokenGeneratorTests` 读取，不拷贝）。
 */
public enum IMDebugTokenGenerator {
    /// 缺省 ttl：12 小时。
    public static let defaultTTLSec = 12 * 3600
    public static let minTTLSec = 60
    /// 服务端 30 天上限是硬约束。
    public static let maxTTLSec = 30 * 24 * 3600
    public static let debugKeyPrefix = "dbg-"

    /// generate 生成调试票。入参不合法抛 `IMRTCError(.badParams)`。
    /// - Parameters:
    ///   - ttlSec: nil 或 0 = 12h，钳到 [60, 2592000]（30 天）。
    ///   - now: 可注入，测试用。
    public static func generate(
        appId: String, keyId: String, secret: String, uid: String,
        deviceId: String? = nil, ttlSec: Int? = nil, now: Date = Date()
    ) throws -> String {
        IMRTCLog.warn("【仅联调】正在用调试密钥在本机签票，上线务必换成后端 /v1/tokens 换票",
                      ["kid": keyId])
        try validate(appId: appId, keyId: keyId, secret: secret, uid: uid)
        let iat = Int(now.timeIntervalSince1970)
        let ttl = (ttlSec ?? 0) == 0 ? defaultTTLSec : min(max(ttlSec ?? 0, minTTLSec), maxTTLSec)
        var claims: [String: Any] = [
            "iss": "im-rtc-server", "sub": uid, "aud": appId,
            "exp": iat + ttl, "iat": iat, "scope": "access",
        ]
        if let deviceId, !deviceId.isEmpty { claims["did"] = deviceId }
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT", "kid": keyId]
        let input = try encode(header) + "." + encode(claims)
        return input + "." + sign(input, secret: secret)
    }

    /// hmacBase64URL：HMAC-SHA256(secret, input) 的 base64url 无填充。测试也用它重算签名。
    static func sign(_ input: String, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(input.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return base64URL(Data(mac))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            return base64URL(data)
        } catch {
            throw IMRTCError(.badParams, "调试票 JSON 编码失败：\(error.localizedDescription)")
        }
    }

    private static func validate(appId: String, keyId: String, secret: String, uid: String) throws {
        if uid.isEmpty || uid.contains(where: \.isWhitespace) || uid.utf8.count > 64 {
            throw IMRTCError(.badParams, "调试票：uid 不能为空、含空白或超过 64 字节")
        }
        if appId.isEmpty { throw IMRTCError(.badParams, "调试票：appId 不能为空") }
        if secret.isEmpty { throw IMRTCError(.badParams, "调试票：secret 不能为空") }
        if !keyId.hasPrefix(debugKeyPrefix) {
            throw IMRTCError(.badParams, "调试票：keyId 必须以 dbg- 开头（别把生产密钥填进来）")
        }
    }
}

/// ObjC 宿主用的调试签票入口（IMProgram 是纯 ObjC 工程，看不见上面的 Swift enum）。**仅联调**，同样只在 DEBUG 构建里存在。
///
/// ObjC 侧：`[IMDebugToken tokenWithAppID:keyID:secret:uid:deviceID:ttlSec:error:]`，失败返回 nil 并填 `error`。
@objc public final class IMDebugToken: NSObject {
    /// - Parameters:
    ///   - deviceID: 空串 = 不绑设备。
    ///   - ttlSec: 0 = 缺省 12h，其余钳到 [60, 30 天]。
    @objc(tokenWithAppID:keyID:secret:uid:deviceID:ttlSec:error:)
    public static func token(appID: String, keyID: String, secret: String, uid: String,
                             deviceID: String, ttlSec: Int) throws -> String {
        try IMDebugTokenGenerator.generate(appId: appID, keyId: keyID, secret: secret, uid: uid,
                                           deviceId: deviceID.isEmpty ? nil : deviceID,
                                           ttlSec: ttlSec == 0 ? nil : ttlSec)
    }
}
#endif
