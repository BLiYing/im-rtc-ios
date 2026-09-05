import UIKit
import IMCallEngine
import IMCallEngineWebRTC
import IMCallKit

/*
 Demo 的拨号页 —— **这一整屏都是「宿主本来就该自己写的那部分」**。

 通话界面一行都不在这里：来电页、九宫格、控制条全在 `IMCallKit` 里，
 这一页只负责登录与拨号。这正是草图 §01 的「用法 B」要证明的事——
 宿主接一行 `kit.start()` 就能拿到整套通话 UI。
 */
final class ViewController: UIViewController {

    private let serverField = UITextField()
    private let userField = UITextField()
    private let calleeField = UITextField()
    private let statusLabel = UILabel()
    private let loginButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let videoButton = UIButton(type: .system)

    private var engine: IMCallEngine?
    private var kit: IMCallKit?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "im-rtc Demo"
        view.backgroundColor = .systemBackground
        buildUI()
        setBusy(loggedIn: false)
    }

    // MARK: - 动作

    @objc private func onLogin() {
        let server = serverField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let user = userField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !server.isEmpty, !user.isEmpty else { return }
        statusLabel.text = "登录中…"

        Task { @MainActor in
            do {
                let token = try await demoLogin(server: server, username: user)
                let wsURL = URL(string: server.replacingOccurrences(of: "http", with: "ws")
                    + "/v1/ws")!
                // 传上媒体适配器就能出声出画。**不传也能跑**——登录、振铃、成员进出、
                // 静音通知一个都不少，那是「只要信令、UI 自己画」的用法。
                let engine = IMCallEngine(url: wsURL, deviceID: "ios-demo-\(user)",
                                          media: IMWebRTCAdapter())
                let kit = IMCallKit(engine: engine)
                kit.start()          // ← 用法 B 的全部内容就是这一行
                self.engine = engine
                self.kit = kit

                try await engine.login(token)
                statusLabel.text = "已登录：\(user)"
                setBusy(loggedIn: true)
            } catch {
                statusLabel.text = "登录失败：\(error)"
            }
        }
    }

    @objc private func onAudioCall() { placeCall(mediaType: "audio") }
    @objc private func onVideoCall() { placeCall(mediaType: "video") }

    private func placeCall(mediaType: String) {
        let callee = calleeField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !callee.isEmpty, let kit else { return }
        // 拨号之后什么都不用管：通话界面由 Kit 按状态自己盖上来、自己收起。
        kit.controller.placeCall([callee], mediaType: mediaType)
    }

    /// demoLogin 走服务端的免密登录（仅 `-demo-login` 下存在）。
    ///
    /// **这一段是「宿主后台该做的事」的示范**，不是 SDK 的一部分：
    /// 真实宿主用自己的账号体系换 token。
    private func demoLogin(server: String, username: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(server)/v1/demo/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "demo", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "登录接口返回异常"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["token"] as? String else {
            throw NSError(domain: "demo", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "应答里没有 token"])
        }
        return token
    }

    // MARK: - 搭界面

    private func setBusy(loggedIn: Bool) {
        loginButton.isEnabled = !loggedIn
        [audioButton, videoButton].forEach { $0.isEnabled = loggedIn }
        calleeField.isEnabled = loggedIn
    }

    private func buildUI() {
        configure(serverField, placeholder: "服务器", text: "http://127.0.0.1:8787")
        configure(userField, placeholder: "用户 ID", text: "alice")
        configure(calleeField, placeholder: "对方 ID", text: "bob")

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        style(loginButton, title: "登录", action: #selector(onLogin))
        style(audioButton, title: "📞 语音呼叫", action: #selector(onAudioCall))
        style(videoButton, title: "📹 视频呼叫", action: #selector(onVideoCall))

        let stack = UIStackView(arrangedSubviews: [
            label("服务器 / 用户"), serverField, userField, loginButton, statusLabel,
            spacer(), label("1v1 通话"), calleeField, audioButton, videoButton,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
        ])
    }

    private func configure(_ field: UITextField, placeholder: String, text: String) {
        field.placeholder = placeholder
        field.text = text
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
    }

    private func style(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func label(_ text: String) -> UILabel {
        let view = UILabel()
        view.text = text
        view.font = .systemFont(ofSize: 13, weight: .semibold)
        view.textColor = .secondaryLabel
        return view
    }

    private func spacer() -> UIView {
        let view = UIView()
        view.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return view
    }
}
