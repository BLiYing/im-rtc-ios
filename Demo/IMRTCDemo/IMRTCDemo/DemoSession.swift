import Foundation
import IMCallEngine
import IMCallEngineWebRTC
import IMCallKit

/*
 Demo 的「宿主状态」：登录态、Engine + Kit、通话记录。三个 tab 共用它。

 # 通话记录完全由回调拼出来

 草图 §02-C：记录是 `callDidEnd(reason, duration)` 的产物，Demo 自己存本地。
 宿主换成消息气泡、换成后台查 `/v1/calls`，都是同一份数据。
 **这里用的是 block 接法**（`addEventObserver`），因为 delegate 已经被 Kit 占着——
 这正是回调表提供两种形式的原因之一：Kit 用一种，宿主用另一种，互不打架。
 */
final class DemoSession {

    static let shared = DemoSession()

    /// 一条通话记录。UserDefaults 存 JSON——**别引 Keychain**（未签名装机不可用）。
    struct Record: Codable, Identifiable {
        var id: String { callID + String(endedAtMS) }
        let callID: String
        let peer: String
        let mediaType: String
        let isGroup: Bool
        let role: String
        let reason: String
        let durationSec: Int
        let endedAtMS: Int64
    }

    private(set) var engine: IMCallEngine?
    private(set) var kit: IMCallKit?
    private(set) var server = ""
    private(set) var token = ""
    private(set) var username = ""
    var deviceID: String { "ios-demo-\(username)" }
    let kitConfig = IMCallKitConfig()

    private var logSink: RemoteLogSink?
    private var observerToken: NSUUID?
    private(set) var records: [Record] = []
    private(set) var connectionText = "未登录"

    /// 状态变了通知界面。三个 tab 各自订阅。
    var onChange: (() -> Void)?

    /// 当前这通电话的元数据，等 callEnd 时拼成记录。
    private var current: (peer: String, mediaType: String, isGroup: Bool, role: String)?

    private init() {
        records = Self.loadRecords()
    }

    // MARK: - 登录 / 退出

    var isLoggedIn: Bool { engine != nil }

    func login(server: String, username: String) async throws {
        let token = try await DemoAPI.login(server: server, username: username)
        self.server = server
        self.username = username
        self.token = token

        // 日志回传（仅开发）：Engine 会把每一个公开事件也写进日志，服务端按时间轴合并。
        let sink = RemoteLogSink(server: server, client: "ios-\(username)")
        sink.start()
        IMRTCLog.setLevel(.debug)
        IMRTCLog.setSink(sink)
        logSink = sink

        let wsURL = URL(string: server.replacingOccurrences(of: "http", with: "ws") + "/v1/ws")!
        let engine = IMCallEngine(url: wsURL, deviceID: deviceID, media: IMWebRTCAdapter())
        let kit = IMCallKit(engine: engine, config: kitConfig)
        kit.start()
        self.engine = engine
        self.kit = kit
        observerToken = engine.addEventObserver { [weak self] event in self?.handle(event) }

        connectionText = "连接中…"
        notify()
        try await engine.login(token)
    }

    func logout() async {
        if let token = observerToken { engine?.removeEventObserver(token) }
        await engine?.logout()
        engine = nil
        kit = nil
        IMRTCLog.setSink(nil)
        logSink = nil
        connectionText = "未登录"
        notify()
    }

    // MARK: - 事件 → 记录

    private func handle(_ event: IMCallEvent) {
        switch event.name {
        case .connected:
            connectionText = "已连接 · \(server.replacingOccurrences(of: "http://", with: ""))"
        case .disconnected:
            let will = (event.payload["will_reconnect"] as? NSNumber)?.boolValue ?? false
            connectionText = will ? "重连中…" : "已断开"
        case .kickedOut:
            connectionText = "登录态失效，请重新登录"
            Task { await self.logout() }
        case .callReceived:
            current = (peer: event.payload["caller"] as? String ?? "",
                       mediaType: event.payload["media_type"] as? String ?? "audio",
                       isGroup: (event.payload["is_group"] as? NSNumber)?.boolValue ?? false,
                       role: "callee")
        case .callBegin:
            // 主叫这边 callReceived 不会来，靠 callBegin 补上 role/mediaType。
            if current == nil {
                current = (peer: "", mediaType: event.payload["media_type"] as? String ?? "audio",
                           isGroup: (event.payload["is_group"] as? NSNumber)?.boolValue ?? false,
                           role: event.payload["role"] as? String ?? "caller")
            }
        case .callEnd:
            let meta = current ?? (peer: "", mediaType: "audio", isGroup: false, role: "caller")
            records.insert(Record(
                callID: event.callID,
                peer: meta.peer.isEmpty ? pendingPeer : meta.peer,
                mediaType: meta.mediaType, isGroup: meta.isGroup, role: meta.role,
                reason: event.payload["reason"] as? String ?? "",
                durationSec: (event.payload["duration_sec"] as? NSNumber)?.intValue ?? 0,
                endedAtMS: Int64(Date().timeIntervalSince1970 * 1000)), at: 0)
            Self.saveRecords(records)
            current = nil
            pendingPeer = ""
        default:
            return
        }
        notify()
    }

    /// 主叫拨号时记下对方是谁——callBegin 的载荷里没有 callee。
    var pendingPeer = ""

    func clearRecords() {
        records = []
        Self.saveRecords(records)
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: - 持久化

    private static let recordsKey = "im-rtc-demo.records"

    private static func loadRecords() -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func saveRecords(_ records: [Record]) {
        // 只留最近 100 条，Demo 不做翻页。
        if let data = try? JSONEncoder().encode(Array(records.prefix(100))) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }
}
