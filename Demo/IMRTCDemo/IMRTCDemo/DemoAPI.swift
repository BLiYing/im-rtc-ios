import Foundation

/*
 Demo 用到的 REST 调用。

 **这一层不是 SDK 的一部分**——它示范的是「宿主后台该做的事」：
 用自己的账号体系换 token、用自己的接口建房、要不要查通话记录也由宿主自己定。
 （Web 端同一层：demo-react/src/api.ts。）
 */
enum DemoAPI {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// demoLogin 走服务端的免密登录（仅 `-demo-login` 下存在）。
    static func login(server: String, username: String) async throws -> String {
        let out = try await post("\(server)/v1/demo/login", body: ["username": username])
        guard let token = out["token"] as? String else { throw Failure(message: "应答里没有 token") }
        return token
    }

    /// createMeetingRoom 建一个会议房，返回房间号。
    static func createMeetingRoom(server: String, token: String) async throws -> String {
        let out = try await post("\(server)/v1/rooms", body: ["kind": "meeting"], bearer: token)
        guard let roomID = out["room_id"] as? String else { throw Failure(message: "应答里没有 room_id") }
        return roomID
    }

    /// fetchRoomToken 给自己换一枚进房票。
    static func fetchRoomToken(server: String, token: String, roomID: String,
                               deviceID: String) async throws -> String {
        let out = try await post("\(server)/v1/rooms/\(roomID)/tokens",
                                 body: ["device_id": deviceID], bearer: token)
        guard let roomToken = out["room_token"] as? String else {
            throw Failure(message: "应答里没有 room_token")
        }
        return roomToken
    }

    /**
     post 发一个请求。**失败时要把服务端说的话带出来**：它回的是
     `{"error":"房间不存在"}`，只报一个 `返回 404` 等于把已经到手的答案扔掉。
     （Web 端踩过：会议房空了就销毁，再拿旧房间号进会议只看到「返回 404」。）
     */
    private static func post(_ url: String, body: [String: Any],
                             bearer: String? = nil) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else { throw Failure(message: "地址不合法：\(url)") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let detail = json["error"] as? String
                ?? String(data: data.prefix(200), encoding: .utf8) ?? "（无正文）"
            throw Failure(message: "\(url) 返回 \(status)：\(detail)")
        }
        return json
    }
}
