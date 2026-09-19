import Foundation

/*
 通话记录查询：`GET /v1/calls`（server 设计文档 §4.5）。

 **宿主不一定要用它**：很多宿主拿 `callDidEnd` 自己存、或拿 webhook 落自己的库就够了。
 想让「换设备、重装之后记录还在」，或者不想自己存，就调这里。

 走的是当前登录用的那枚接入票（含 `updateToken` 换过的），服务端据此**只返回本人参与过的通话**——
 所以这里没有 `uid` 参数，也不能查别人。要查全租户走宿主后台的 HMAC 接口，不是 SDK 的事。
 */

/// 通话记录里的一位成员。
public struct IMCallHistoryMember: Equatable, Sendable {
    public let uid: String
    /// 这位成员在这通电话里的结局（如 `joined`、`no_answer`、`busy`…），原样透传。
    public let state: String
}

/// 一条通话记录。字段含义与服务端 `GET /v1/calls` 一一对应。
public struct IMCallHistoryRecord: Equatable, Sendable {
    public let callID: String
    public let roomID: String
    public let caller: String
    /// `audio` 或 `video`。
    public let mediaType: String
    public let isGroup: Bool
    /// 通话的最终结局（`hangup`、`cancel`、`reject`、`no_answer`…），**不分角色**：
    /// 要显示「已取消」还是「对方已取消」，用 `caller` 与自己的 `uid` 比出角色，
    /// 再交给 ``imEndReasonText``。
    public let reason: String
    public let endedBy: String
    public let durationSec: Int
    public let startedAtMS: Int64
    public let connectedAtMS: Int64
    public let endedAtMS: Int64
    public let userData: String
    public let chatGroupID: String
    public let members: [IMCallHistoryMember]
}

/// 一页通话记录（按发起时间倒序）。
public struct IMCallHistoryPage: Equatable, Sendable {
    public let records: [IMCallHistoryRecord]
    /// 下一页的游标，传给下一次 `fetchCallHistory(cursor:)`。**nil 表示已经到底**。
    public let nextCursor: Int64?
}

extension IMCallEngine {

    /// 服务端每页上限（`maxCallLimit`）。超过它服务端也只回这么多，
    /// 「到底」的判据就不成立了，所以本地先夹住。
    static let maxCallHistoryLimit = 200

    /**
     fetchCallHistory 查自己的通话记录，按发起时间倒序，**游标翻页**。

     - Parameter limit: 每页条数，夹在 1...200，默认 20。
     - Parameter cursor: 首页不传；下一页传上一页返回的 `nextCursor`。

     **必须已登录**（要用登录那枚票），否则抛 `notLoggedIn`（2007）。
     票过期或被拒抛 `tokenInvalid`（1101）；网络不通抛 `networkUnreachable`（2003）。
     */
    public func fetchCallHistory(limit: Int = 20, cursor: Int64? = nil) async throws -> IMCallHistoryPage {
        try guardNotDestroyed()
        guard let token = currentConnection?.currentToken else {
            throw IMRTCError(.notLoggedIn, "fetchCallHistory：请先 login")
        }
        let clamped = min(max(limit, 1), Self.maxCallHistoryLimit)
        let request = try Self.makeCallHistoryRequest(
            signalingURL: url, token: token, limit: clamped, cursor: cursor)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw IMRTCError(.networkUnreachable, "查通话记录失败：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parseCallHistory(status: status, body: data, limit: clamped)
    }

    // MARK: - 纯函数（可单测，不碰网络）

    /// 信令地址推出 REST 根：`ws→http`、`wss→https`，去掉末尾的 `/v1/ws`。
    static func restBaseURL(fromSignalingURL url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "ws": parts.scheme = "http"
        case "wss": parts.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        if parts.path.hasSuffix("/v1/ws") { parts.path.removeLast("/v1/ws".count) }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func makeCallHistoryRequest(signalingURL: URL, token: String,
                                       limit: Int, cursor: Int64?) throws -> URLRequest {
        guard let base = restBaseURL(fromSignalingURL: signalingURL),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw IMRTCError(.badParams, "信令地址无法推出 REST 地址：\(signalingURL.absoluteString)")
        }
        parts.path += "/v1/calls"
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, cursor > 0 { items.append(URLQueryItem(name: "cursor", value: String(cursor))) }
        parts.queryItems = items
        guard let target = parts.url else {
            throw IMRTCError(.badParams, "拼不出通话记录请求地址")
        }
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func parseCallHistory(status: Int, body: Data, limit: Int) throws -> IMCallHistoryPage {
        switch status {
        case 200: break
        case 401: throw IMRTCError(.tokenInvalid, "查通话记录被拒（401）：票无效或已过期")
        default: throw IMRTCError(.internalError, "查通话记录失败：HTTP \(status)")
        }
        let wire: WireCallList
        do {
            wire = try JSONDecoder().decode(WireCallList.self, from: body)
        } catch {
            throw IMRTCError(.internalError, "通话记录应答解析失败：\(error.localizedDescription)")
        }
        let records = wire.calls.map { $0.record }
        // 服务端只要这页有数据就给 next_cursor，没有「到底」标志：
        // 不满一页就一定是最后一页，满页才交出游标（最坏多翻一页空的）。
        let next: Int64? = records.count >= limit ? wire.next_cursor : nil
        return IMCallHistoryPage(records: records, nextCursor: next)
    }
}

// MARK: - 线路格式（snake_case，缺字段一律给零值，服务端加字段不该把这里打崩）

private struct WireCallList: Decodable {
    let calls: [WireCall]
    let next_cursor: Int64?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent([WireCall].self, forKey: .calls) ?? []
        next_cursor = try c.decodeIfPresent(Int64.self, forKey: .next_cursor)
    }
    private enum CodingKeys: String, CodingKey { case calls, next_cursor }
}

private struct WireCall: Decodable {
    let record: IMCallHistoryRecord

    private enum K: String, CodingKey {
        case call_id, room_id, caller, media_type, is_group, reason, ended_by, duration_sec
        case started_at_ms, connected_at_ms, ended_at_ms, user_data, chat_group_id, members
    }
    private struct Member: Decodable { let uid: String?; let state: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func str(_ k: K) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? "" }
        func num(_ k: K) throws -> Int64 { try c.decodeIfPresent(Int64.self, forKey: k) ?? 0 }
        let members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        record = IMCallHistoryRecord(
            callID: try str(.call_id), roomID: try str(.room_id), caller: try str(.caller),
            mediaType: try str(.media_type),
            isGroup: try c.decodeIfPresent(Bool.self, forKey: .is_group) ?? false,
            reason: try str(.reason), endedBy: try str(.ended_by),
            durationSec: Int(try num(.duration_sec)),
            startedAtMS: try num(.started_at_ms), connectedAtMS: try num(.connected_at_ms),
            endedAtMS: try num(.ended_at_ms),
            userData: try str(.user_data), chatGroupID: try str(.chat_group_id),
            members: members.map { IMCallHistoryMember(uid: $0.uid ?? "", state: $0.state ?? "") })
    }
}
