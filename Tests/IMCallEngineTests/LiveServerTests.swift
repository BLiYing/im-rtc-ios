import XCTest
@testable import IMCallEngine

/*
 对着**真服务端**跑的联调测试。

 默认不跑：没设 `RTC_LIVE_SERVER` 就直接返回。这不是「静默跳过一致性测试」那种
 坏味道——它测的是网络连通性，不是协议一致性，而协议一致性由向量在每次回归里守着。
 起服务端之后手动跑：

     cd ../im-rtc-server && ./scripts/dev.sh
     RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests

 它验的是与 `rtc-cli -scenario room` 等价的流程：
 免密登录 → WS 握手 → 建会议房 → 换进房票 → 进房 → 离房。
 **不碰媒体**，所以不需要真机也不需要模拟器。
 */
final class LiveServerTests: XCTestCase {
    private var base: String?

    override func setUp() {
        base = ProcessInfo.processInfo.environment["RTC_LIVE_SERVER"]
    }

    func testJoinAndLeaveMeetingRoom() async throws {
        guard let base else {
            // 用 XCTSkip 而不是静默 return：跑测试的人应当看得见「这条没跑」。
            throw XCTSkip("没设 RTC_LIVE_SERVER，跳过真服务端联调")
        }

        let username = "swift-live-\(Int.random(in: 1000...9999))"
        let token = try await demoLogin(base: base, username: username)
        let roomID = try await createMeetingRoom(base: base, token: token)

        var options = IMConnectionOptions(
            url: URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/v1/ws")!,
            token: token, deviceID: "swift-\(username)")
        options.requestTimeoutMS = 8_000

        let events = IMConnectionEvents()
        let connection = IMSignalConnection(options: options, events: events)

        let hello = try await connection.connect()
        XCTAssertEqual(hello.uid, username)
        XCTAssertFalse(hello.sessionID.isEmpty)
        XCTAssertEqual(hello.maxRoomParticipants, 9, "服务端下发的限额应当与协议一致")

        let roomToken = try await fetchRoomToken(base: base, token: token, roomID: roomID,
                                                 deviceID: options.deviceID)

        // **从 defaults 起手再改字段**：直接发零值会把 auto_subscribe 写成 false，
        // 人进了房却收不到任何流（§2.4 的发送侧陷阱）。
        var joinData = FieldCodec.defaults(RoomFrames.join)
        joinData["room_id"] = .string(roomID)
        joinData["room_token"] = .string(roomToken)

        let joined = try await connection.request(IMFrameType.roomJoin, data: joinData)
        XCTAssertEqual(joined.envelope.type, IMEnvelope.okType(IMFrameType.roomJoin))
        XCTAssertEqual(joined.data["room_id"]?.stringValue, roomID)
        XCTAssertFalse(joined.data["participant_id"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(joined.data["room_kind"]?.stringValue, "meeting")

        let left = try await connection.request(IMFrameType.roomLeave,
                                                data: ["room_id": .string(roomID)])
        XCTAssertEqual(left.envelope.type, IMEnvelope.okType(IMFrameType.roomLeave))

        // 主动关闭要发出干净的 1000。给关闭帧一点时间飞出去——
        // 不等的话进程先退出，服务端看到的是 1006，会白留 30 秒恢复窗口。
        connection.close()
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - REST（这部分是**宿主后台该做的事**的示范，不是 SDK 的一部分）

    private func demoLogin(base: String, username: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["username": username])
        let json = try await post(url: base + "/v1/demo/login", body: body, bearer: nil)
        return json["token"] as? String ?? ""
    }

    private func createMeetingRoom(base: String, token: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["kind": "meeting"])
        let json = try await post(url: base + "/v1/rooms", body: body, bearer: token)
        return json["room_id"] as? String ?? ""
    }

    private func fetchRoomToken(base: String, token: String, roomID: String,
                                deviceID: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["device_id": deviceID])
        let json = try await post(url: base + "/v1/rooms/\(roomID)/tokens", body: body, bearer: token)
        return json["room_token"] as? String ?? ""
    }

    private func post(url: String, body: Data, bearer: String?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IMRTCError(.networkUnreachable, "\(url) 返回非 200")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
