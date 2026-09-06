import UIKit
import IMCallKit

/*
 拨号页（草图 §02-B）：顶部身份卡 + 三块对应三种玩法：1v1 / 群通话 / 会议房间。

 **这一整屏都是宿主代码**——联系人从哪来、群怎么组织，SDK 一概不管。
 它只调 `kit.controller.placeCall` 与 `joinMeeting`。通话界面一行都不在这里。
 */
final class DialerViewController: UIViewController {

    private let session = DemoSession.shared

    private let serverField = DemoUI.field(placeholder: DemoSession.serverPlaceholder,
                                           text: DemoSession.defaultServer)
    private let userField = DemoUI.field(placeholder: "用户 ID", text: DemoSession.defaultUsername)
    private let calleeField = DemoUI.field(placeholder: "对方 ID", text: DemoSession.defaultCallee)
    private let roomField = DemoUI.field(placeholder: "房间号（留空则新建）", text: "")
    private let groupLabel = UILabel()
    private let statusLabel = UILabel()
    /// 登录这一步自己的进度与错误。**必须贴着登录按钮**，见 onLogin 的注释。
    private let loginHint = UILabel()
    private let errorLabel = UILabel()
    private let loginButton = UIButton(type: .system)
    private let logoutButton = UIButton(type: .system)
    private var callButtons: [UIButton] = []
    /// 群呼默认名单。**不能含登录的那个人**——服务端会以 1004 拒掉整通电话
    /// （"callee_ids 不能含主叫自己"）。登录后 refresh() 会把自己剔掉。
    private var groupPick: [String] = ["alice", "carol"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "拨号"
        view.backgroundColor = .systemGroupedBackground
        build()
        session.onChange = { [weak self] in self?.refresh() }
        refresh()
        // 上次登录过就自动重登——**杀掉 app 再打开不该回到登录页**。
        Task { await session.autoLogin() }
    }

    private func refresh() {
        statusLabel.text = session.connectionText
        let loggedIn = session.isLoggedIn
        if loggedIn { setLoginHint("") }
        loginButton.isHidden = loggedIn
        logoutButton.isHidden = !loggedIn
        serverField.isEnabled = !loggedIn
        userField.isEnabled = !loggedIn
        callButtons.forEach { $0.isEnabled = loggedIn }
        // 把自己从群呼名单里剔掉：带着自己发出去，服务端会拒掉**整通**电话。
        let me = session.username
        if !me.isEmpty, groupPick.contains(me) {
            groupPick.removeAll { $0 == me }
        }
        groupLabel.text = groupPick.isEmpty ? "👥 （请选人）" : "👥 " + groupPick.joined(separator: "、")
    }

    // MARK: - 动作

    /**
     登录。**每一条出路都要在按钮旁边留下一句话**——真机上报过来的是「点登录没有任何反应」，
     两条路都会走成那个样子：

     · 地址或用户名是空的（真机首次装机地址就是空的，见 `DemoSession.defaultServer`）
       原先直接 `return`，界面上一个字都不变，看起来就是按钮坏了；
     · 请求发出去了要等（超时 10s），期间界面同样一个字都不变，而失败后那句话
       落在整页最下面的 `errorLabel` 上——小屏上它在折叠线以下，不滚到底根本看不见。

     所以：空值当场说清楚，发请求前先写「登录中…」并禁用按钮，失败也写在同一行。
    */
    @objc private func onLogin() {
        errorLabel.text = ""
        let server = serverField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let user = userField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !server.isEmpty else { return setLoginHint("请先填服务器地址（\(DemoSession.serverPlaceholder)）") }
        guard !user.isEmpty else { return setLoginHint("请先填用户 ID") }
        setLoginHint("登录中…", isError: false)
        loginButton.isEnabled = false
        Task { @MainActor in
            do {
                try await session.login(server: server, username: user)
                setLoginHint("")
            } catch {
                setLoginHint(error.localizedDescription)
            }
            loginButton.isEnabled = true
        }
    }

    /// 空文案要把整行收起来——留一个空 label 在那儿，身份卡里会平白多出一条缝。
    private func setLoginHint(_ text: String, isError: Bool = true) {
        loginHint.text = text
        loginHint.textColor = isError ? .systemRed : .secondaryLabel
        loginHint.isHidden = text.isEmpty
    }

    @objc private func onLogout() { run { await self.session.logout() } }

    @objc private func onAudio() { place(mediaType: "audio") }
    @objc private func onVideo() { place(mediaType: "video") }

    private func place(mediaType: String) {
        let callee = calleeField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !callee.isEmpty, let kit = session.kit else { return }
        session.pendingPeer = callee
        kit.controller.placeCall([callee], mediaType: mediaType)
    }

    @objc private func onPickGroup() {
        let picker = ContactPickerViewController(selected: groupPick) { [weak self] picked in
            self?.groupPick = picked
            self?.refresh()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    @objc private func onGroupCall() {
        guard !groupPick.isEmpty, let kit = session.kit else { return }
        session.pendingPeer = "群通话 · \(groupPick.count + 1) 人"
        kit.controller.placeCall(groupPick, mediaType: "video", isGroup: true)
    }

    @objc private func onJoinMeeting() {
        errorLabel.text = ""
        guard let kit = session.kit else { return }
        let typed = roomField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        run {
            let roomID = typed.isEmpty
                ? try await DemoAPI.createMeetingRoom(server: self.session.server,
                                                      token: self.session.token)
                : typed
            let roomToken = try await DemoAPI.fetchRoomToken(
                server: self.session.server, token: self.session.token,
                roomID: roomID, deviceID: self.session.deviceID)
            await MainActor.run {
                // 把房间号留在框里，方便复制给另一台设备。
                self.roomField.text = roomID
                kit.controller.joinMeeting(roomID: roomID, roomToken: roomToken)
            }
        }
    }

    /// run 跑一段异步动作，失败就把错误摆在页面上——不弹 alert，弹窗会挡住通话页。
    private func run(_ body: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await body() } catch { errorLabel.text = error.localizedDescription }
        }
    }

    // MARK: - 搭界面

    private func build() {
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        loginHint.font = .systemFont(ofSize: 13)
        loginHint.numberOfLines = 0
        loginHint.isHidden = true
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        groupLabel.font = .systemFont(ofSize: 15)

        DemoUI.style(loginButton, title: "登录", action: #selector(onLogin), target: self)
        DemoUI.style(logoutButton, title: "退出", action: #selector(onLogout), target: self)
        let audio = DemoUI.button("📞 语音", #selector(onAudio), self)
        let video = DemoUI.button("📹 视频", #selector(onVideo), self)
        let pick = DemoUI.button("选人 ›", #selector(onPickGroup), self)
        let group = DemoUI.button("发起群通话", #selector(onGroupCall), self)
        let join = DemoUI.button("加入房间", #selector(onJoinMeeting), self)
        callButtons = [audio, video, pick, group, join]

        let stack = UIStackView(arrangedSubviews: [
            DemoUI.card("身份", [serverField, DemoUI.note(DemoSession.serverHint),
                               userField, statusLabel, loginButton, logoutButton, loginHint]),
            DemoUI.card("单人通话", [calleeField, DemoUI.row([audio, video])]),
            DemoUI.card("多人通话（最多 8 人）", [DemoUI.row([groupLabel, pick]), group]),
            DemoUI.card("会议房间", [roomField, join,
                                 DemoUI.note("会议不走振铃，直接进房。把房间号发给另一台设备就能双开。")]),
            errorLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        DemoUI.scroll(stack, in: view)
    }
}
