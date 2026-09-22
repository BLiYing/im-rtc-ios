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
    private let userField = DemoUI.field(placeholder: dt("demo.field.userId"), text: DemoSession.defaultUsername)
    private let calleeField = DemoUI.field(placeholder: dt("demo.field.calleeId"), text: DemoSession.defaultCallee)
    private let roomField = DemoUI.field(placeholder: dt("demo.field.roomId"), text: "")
    /// 按 call_id 主动加入一通正在进行的群通话（`IMCallKit.joinCall(_:)`，HOST_INTEGRATION_DESIGN §3.4）。
    /// **真实宿主怎么知道有通话在进行中不在本协议里**——这里让人手填 call_id 只是为了验证这条路径。
    private let joinCallField = DemoUI.field(placeholder: "call_id", text: "")
    private let groupLabel = UILabel()
    private let statusLabel = UILabel()
    /// 登录这一步自己的进度与错误。**必须贴着登录按钮**，见 onLogin 的注释。
    private let loginHint = UILabel()
    private let errorLabel = UILabel()
    private let loginButton = UIButton(type: .system)
    private let logoutButton = UIButton(type: .system)
    /// 合成画面开关。**模拟器上默认开**——那儿没有摄像头，不开就只能看头像。
    private let syntheticSwitch = UISwitch()
    private var callButtons: [UIButton] = []
    /// 群呼默认名单。**不能含登录的那个人**——服务端会以 1004 拒掉整通电话
    /// （"callee_ids 不能含主叫自己"）。登录后 refresh() 会把自己剔掉。
    private var groupPick: [String] = ["alice", "carol"]
    /// `session.addChangeObserver` 的退订 token。
    private var changeObserverToken: UUID?

    deinit {
        if let changeObserverToken { session.removeChangeObserver(changeObserverToken) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = dt("demo.tab.dial")
        view.backgroundColor = .systemGroupedBackground
        build()
        changeObserverToken = session.addChangeObserver { [weak self] in self?.refresh() }
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
        // 适配器是登录时造的，登录之后再拨这个开关不会生效——干脆锁上，别给假承诺。
        syntheticSwitch.isEnabled = !loggedIn
        syntheticSwitch.isOn = session.syntheticVideo
        callButtons.forEach { $0.isEnabled = loggedIn }
        // 把自己从群呼名单里剔掉：带着自己发出去，服务端会拒掉**整通**电话。
        let me = session.username
        if !me.isEmpty, groupPick.contains(me) {
            groupPick.removeAll { $0 == me }
        }
        groupLabel.text = groupPick.isEmpty ? dt("demo.dial.pickEmpty") : "👥 " + groupPick.joined(separator: dt("demo.dial.listSep"))
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
        guard !server.isEmpty else { return setLoginHint(dt("demo.dial.err.needServer", ["hint": DemoSession.serverPlaceholder])) }
        guard !user.isEmpty else { return setLoginHint(dt("demo.dial.err.needUser")) }
        setLoginHint(dt("demo.login.busy"), isError: false)
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

    /**
     「合成画面」这一行：一句说明 + 一个开关。

     放在身份卡而不是设置页：它**只在登录那一刻起作用**（适配器是登录时造的），
     和服务器地址、用户名是同一批要在按「登录」之前定好的东西。
     与 Web Demo 登录框里那个勾选框对齐。
    */
    private func syntheticRow() -> UIStackView {
        let label = UILabel()
        label.text = dt("demo.dial.synthetic")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        syntheticSwitch.isOn = session.syntheticVideo
        syntheticSwitch.addTarget(self, action: #selector(onToggleSynthetic), for: .valueChanged)
        syntheticSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, syntheticSwitch])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    @objc private func onToggleSynthetic() {
        session.syntheticVideo = syntheticSwitch.isOn
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
        kit.controller.placeCall([callee], mediaType: mediaType)
    }

    @objc private func onPickGroup() {
        let picker = ContactPickerViewController(selected: groupPick) { [weak self] picked in
            self?.groupPick = picked
            self?.refresh()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    /// 群呼时带上 Demo 自己的群号（HOST_INTEGRATION_DESIGN §3.2）：被叫与中途加入的人
    /// 靠它知道「这通电话属于哪个群」，Kit 的「添加成员」也靠它决定该问谁要候选人
    /// （见 `DemoInviteProvider`）。真实宿主这里传的是自己 IM 里的群 id。
    private static let demoChatGroupID = "demo-group"

    @objc private func onGroupCall() {
        guard !groupPick.isEmpty, let kit = session.kit else { return }
        kit.controller.placeCall(groupPick, mediaType: "video", isGroup: true,
                                 chatGroupID: Self.demoChatGroupID)
    }

    /// 按 call_id 加入一通正在进行的群通话（草图 §3.4 的「主动加入」）。
    @objc private func onJoinByCallID() {
        errorLabel.text = ""
        let callID = joinCallField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !callID.isEmpty else { return errorLabel.text = dt("demo.dial.err.needCallId") }
        guard let kit = session.kit else { return errorLabel.text = dt("demo.dial.err.notLoggedIn") }
        kit.joinCall(callID)
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

        DemoUI.style(loginButton, title: dt("demo.login.title"), action: #selector(onLogin), target: self)
        DemoUI.style(logoutButton, title: dt("demo.logout"), action: #selector(onLogout), target: self)
        let audio = DemoUI.button(dt("demo.dial.audio"), #selector(onAudio), self)
        let video = DemoUI.button(dt("demo.dial.video"), #selector(onVideo), self)
        let pick = DemoUI.button(dt("demo.dial.pick"), #selector(onPickGroup), self)
        let group = DemoUI.button(dt("demo.dial.startGroup"), #selector(onGroupCall), self)
        let join = DemoUI.button(dt("demo.dial.joinRoom"), #selector(onJoinMeeting), self)
        let joinCall = DemoUI.button(dt("demo.dial.joinThisCall"), #selector(onJoinByCallID), self)
        callButtons = [audio, video, pick, group, join, joinCall]

        let stack = UIStackView(arrangedSubviews: [
            DemoUI.card(dt("demo.identity"), [serverField, DemoUI.note(DemoSession.serverHint),
                               userField, syntheticRow(), statusLabel,
                               loginButton, logoutButton, loginHint]),
            DemoUI.card(dt("demo.dial.single"), [calleeField, DemoUI.row([audio, video])]),
            DemoUI.card(dt("demo.dial.groupLimit", ["n": 8]), [DemoUI.row([groupLabel, pick]), group,
                                        DemoUI.note(dt("demo.dial.groupNoteIos", ["id": Self.demoChatGroupID]))]),
            DemoUI.card(dt("demo.dial.joinGroupCall"), [joinCallField, joinCall,
                                       DemoUI.note(dt("demo.dial.joinCallNoteIos"))]),
            DemoUI.card(dt("demo.dial.meeting"), [roomField, join,
                                 DemoUI.note(dt("demo.dial.meetingNote"))]),
            errorLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        DemoUI.scroll(stack, in: view)
    }
}
