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

    // MARK: - 服务器地址

    /**
     上次用的服务器地址；没用过就给一个默认值。

     **模拟器与真机的默认值必须不一样**：模拟器与 Mac 共用网络栈，`127.0.0.1`
     就是 Mac 本身，开箱即用；真机上 `127.0.0.1` 指的是**手机自己**，永远连不上。

     真机上**留空**，靠 placeholder 说该填什么。不预填一个像模像样的假 IP
     （比如 192.168.1.100）：那种地址一眼看不出是错的，人会以为服务端挂了，
     去查服务端日志——而那边根本没有请求进来，最难查的一类。

     填过一次就记住（`UserDefaults`）：真机联调时不用每次启动都重敲一遍 IP。
     */
    static var defaultServer: String {
        if let saved = UserDefaults.standard.string(forKey: serverKey), !saved.isEmpty {
            return saved
        }
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:8787"
        #else
        return "" // 见上：真机不预填假地址，让 placeholder 说话
        #endif
    }

    /// 真机上输入框的占位文案。模拟器上用不到（默认值已经是对的）。
    static var serverPlaceholder: String {
        #if targetEnvironment(simulator)
        return "服务器"
        #else
        return "http://<Mac 的局域网 IP>:8787"
        #endif
    }

    /// 默认 **bob**：Web Demo 默认 alice，两端刚好错开，双端联调不用改用户名。
    static var defaultUsername: String {
        UserDefaults.standard.string(forKey: userKey) ?? "bob"
    }

    /// 默认呼叫对象 **alice**（= Web 那边的默认登录名）。
    static var defaultCallee: String {
        UserDefaults.standard.string(forKey: userKey) == "alice" ? "bob" : "alice"
    }

    /**
     上次登录过就自动重登。**杀掉 app 再打开不该回到登录页。**

     记的是「用什么去换 token」而不是 token 本身：token 会过期，
     重启后本来就该走一次正常的换票流程（真实宿主也一样——用自己的会话换新票）。
     */
    static var canAutoLogin: Bool {
        UserDefaults.standard.bool(forKey: autoKey)
            && !defaultServer.isEmpty
            && !(UserDefaults.standard.string(forKey: userKey) ?? "").isEmpty
    }

    func autoLogin() async {
        guard Self.canAutoLogin, !isLoggedIn else { return }
        let server = Self.defaultServer
        let user = UserDefaults.standard.string(forKey: Self.userKey) ?? ""
        do {
            try await login(server: server, username: user)
        } catch {
            // 自动重登失败就安静地留在登录页——不弹错误，用户没主动做这件事。
            IMRTCLog.info("自动重登失败", ["err": String(describing: error)])
        }
    }

    private static let autoKey = "im-rtc-demo.autoLogin"

    /// 真机上要提示人去改地址；模拟器上默认值就是对的，不用啰嗦。
    static var serverHint: String {
        #if targetEnvironment(simulator)
        return "模拟器与 Mac 共用网络，127.0.0.1 直接可用。"
        #else
        return "真机请填 Mac 的局域网 IP（启动 dev.sh 时会打印），127.0.0.1 在手机上指手机自己。"
        #endif
    }

    private static let serverKey = "im-rtc-demo.server"
    private static let userKey = "im-rtc-demo.username"

    // MARK: - 登录 / 退出

    var isLoggedIn: Bool { engine != nil }

    func login(server: String, username: String) async throws {
        let token = try await DemoAPI.login(server: server, username: username)
        self.server = server
        self.username = username
        self.token = token
        // 登录成功才记住——**失败的地址不该被记下来**，否则一次手滑之后
        // 每次启动都带着那个错地址，还以为是默认值有问题。
        UserDefaults.standard.set(server, forKey: Self.serverKey)
        UserDefaults.standard.set(username, forKey: Self.userKey)
        UserDefaults.standard.set(true, forKey: Self.autoKey)

        // 日志回传（仅开发）：Engine 会把每一个公开事件也写进日志，服务端按时间轴合并。
        let sink = RemoteLogSink(server: server, client: "ios-\(username)")
        sink.start()
        IMRTCLog.setLevel(.debug)
        IMRTCLog.setSink(sink)
        logSink = sink

        let wsURL = URL(string: server.replacingOccurrences(of: "http", with: "ws") + "/v1/ws")!
        /*
         画质档位是**宿主策略**（见 IMVideoProfile 的说明）：真实宿主会从自己的
         配置接口拿这个值——「后台可控」在产品上就是这个意思，不需要动 RTC 协议。
         Demo 把它放在设置页里，换档位下一通电话生效。
        */
        let engine = IMCallEngine(url: wsURL, deviceID: deviceID,
                                  media: IMWebRTCAdapter(videoProfile: videoProfile))
        let kit = IMCallKit(engine: engine, config: kitConfig)
        kit.start()
        self.engine = engine
        self.kit = kit
        observerToken = engine.addEventObserver { [weak self] event in self?.handle(event) }

        connectionText = "连接中…"
        notify()
        try await engine.login(token)
    }

    /// 采集画质档位。**换了要重登才生效**——适配器是登录时造的。
    var videoProfile: IMVideoProfile = .default {
        didSet { notify() }
    }

    func logout() async {
        // 主动退出就别再自动重登了——那是用户的明确意思。
        UserDefaults.standard.set(false, forKey: Self.autoKey)
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
            // 被踢之后别再自动重登，否则重启就撞回同一个死胡同。
            UserDefaults.standard.set(false, forKey: Self.autoKey)
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
