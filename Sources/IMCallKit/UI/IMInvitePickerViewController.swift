#if canImport(UIKit)
import UIKit

/*
 「添加成员」的选人页（交互稿 §05 G2）：搜索 + 列表 + 底部「邀请 N 人」。

 **候选名单是宿主给的**（`IMCallKitConfig.inviteCandidates`）——Kit 不内置联系人系统
 （CONVENTIONS §11）。宿主没给名单时退化成一个 uid 输入框，功能不缺、只是没那么顺手。
 已在通话里的人**置灰 + 勾选禁用**，不是隐藏：用户要能看到「他已经在里面了」。
 顶部实时算「还能加 N 人」= 9 − 当前人数 − 已选。
 */
final class IMInvitePickerViewController: UITableViewController, UISearchBarDelegate {

    private let controller: IMCallController
    private let searchBar = UISearchBar()
    private let inviteButton = UIButton(type: .system)
    private var picked: [String] = []
    private var query = ""

    init(controller: IMCallController) {
        self.controller = controller
        super.init(style: .insetGrouped)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController { sheet.detents = [.medium(), .large()] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    private var inCall: Set<String> { Set(controller.state.participants.map(\.uid)) }
    private var candidates: [IMInviteCandidate] {
        // 宿主的名单里多半含自己；自己不能邀请自己，直接不列。
        controller.inviteCandidates.filter { $0.uid != controller.engine.uid }
    }
    private var shown: [IMInviteCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.uid.contains(q) || $0.name.contains(q) }
    }
    private var typedUID: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard candidates.isEmpty, !q.isEmpty, !inCall.contains(q), !picked.contains(q) else { return nil }
        return q
    }
    private var slotsLeft: Int { imInviteSlotsLeft(for: controller.state) - picked.count }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = IMKitTheme.current
        title = "添加成员"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = theme.banner
        tableView.backgroundColor = theme.banner
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: IMKitIcon.xmark.image(pointSize: 15), style: .plain, target: self, action: #selector(close))
        searchBar.placeholder = candidates.isEmpty ? "输入对方 uid" : "搜索联系人"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        tableView.tableHeaderView = searchBar
        searchBar.sizeToFit()

        inviteButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        inviteButton.layer.cornerRadius = 12
        inviteButton.addTarget(self, action: #selector(invite), for: .touchUpInside)
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 76))
        inviteButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(inviteButton)
        NSLayoutConstraint.activate([
            inviteButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            inviteButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            inviteButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            inviteButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        tableView.tableFooterView = footer
        refreshChrome()
    }

    private func refreshChrome() {
        let theme = IMKitTheme.current
        navigationItem.prompt = "还能加 \(max(slotsLeft, 0)) 人"
        inviteButton.setTitle(picked.isEmpty ? "邀请" : "邀请 \(picked.count) 人", for: .normal)
        inviteButton.backgroundColor = picked.isEmpty ? theme.controlBackground : theme.accept
        inviteButton.setTitleColor(picked.isEmpty ? theme.secondaryText : theme.acceptText, for: .normal)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func invite() {
        guard !picked.isEmpty else { return }
        controller.inviteMore(picked)
        dismiss(animated: true)
    }

    private func toggle(_ uid: String) {
        if let index = picked.firstIndex(of: uid) {
            picked.remove(at: index)
        } else if slotsLeft > 0 {
            picked.append(uid)
        }
        refreshChrome()
        tableView.reloadData()
    }

    // MARK: 搜索

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        if let typedUID { toggle(typedUID); query = ""; searchBar.text = "" }
        searchBar.resignFirstResponder()
    }

    // MARK: 列表：第 0 节是「已选但不在名单里的」+「输入的 uid」，第 1 节是名单。

    private var extraRows: [String] {
        let outside = picked.filter { uid in !candidates.contains { $0.uid == uid } }
        return outside + (typedUID.map { [$0] } ?? [])
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? extraRows.count : shown.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = IMKitTheme.current
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        cell.backgroundColor = UIColor(white: 1, alpha: 0.05)
        cell.textLabel?.textColor = theme.primaryText
        cell.detailTextLabel?.textColor = theme.secondaryText
        if indexPath.section == 0 {
            let uid = extraRows[indexPath.row]
            let isPicked = picked.contains(uid)
            cell.textLabel?.text = isPicked ? uid : "邀请 \(uid)"
            cell.accessoryType = isPicked ? .checkmark : .none
            cell.tintColor = theme.accept
            cell.selectionStyle = .default
            cell.textLabel?.alpha = 1
            return cell
        }
        let candidate = shown[indexPath.row]
        let already = inCall.contains(candidate.uid)
        cell.textLabel?.text = already ? "\(candidate.name)（已在通话中）" : candidate.name
        cell.textLabel?.alpha = already ? 0.45 : 1
        cell.accessoryType = already || picked.contains(candidate.uid) ? .checkmark : .none
        cell.tintColor = already ? theme.secondaryText : theme.accept
        cell.selectionStyle = already ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let uid = extraRows[indexPath.row]
            toggle(uid)
            if !candidates.contains(where: { $0.uid == uid }) { query = ""; searchBar.text = "" }
            return
        }
        let candidate = shown[indexPath.row]
        guard !inCall.contains(candidate.uid) else { return }
        toggle(candidate.uid)
    }
}
#endif
