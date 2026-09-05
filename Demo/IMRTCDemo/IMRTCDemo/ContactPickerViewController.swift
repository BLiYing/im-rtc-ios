import UIKit

/*
 群呼选人（草图 §05-I）。**联系人来自本地写死的列表**——CONVENTIONS §11：
 不内置好友/联系人系统，Demo 的联系人来自本地文件，宿主用自己的。

 上限 8 个：自己 + 8 = 9 人，正好 3×3（拍板 §11-1）。

 **名单要 9 个人。** 自己会被过滤掉，8 个名字只剩 7 个可选，
 于是最多凑出 8 格，**永远看不到真正的九宫格**。
 */
final class ContactPickerViewController: UITableViewController {

    /// **把自己排除掉**：呼叫名单里含主叫的话，服务端会以 1004 拒掉整通电话。
    private let contacts =
        ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan"]
            .filter { $0 != DemoSession.shared.username }
    private var selected: Set<String>
    private let onDone: ([String]) -> Void
    private let limit = 8

    init(selected: [String], onDone: @escaping ([String]) -> Void) {
        self.selected = Set(selected)
        self.onDone = onDone
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Demo 不用 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选人"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成", style: .done, target: self, action: #selector(done))
        updateTitle()
    }

    @objc private func done() {
        // 按联系人列表的顺序回传，跟用户勾选的顺序无关——稳定的顺序更好核对。
        onDone(contacts.filter { selected.contains($0) })
        navigationController?.popViewController(animated: true)
    }

    private func updateTitle() {
        navigationItem.prompt = "已选 \(selected.count) / \(limit)"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        contacts.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        let name = contacts[indexPath.row]
        cell.textLabel?.text = name
        cell.accessoryType = selected.contains(name) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let name = contacts[indexPath.row]
        if selected.contains(name) {
            selected.remove(name)
        } else if selected.count < limit {
            selected.insert(name)
        } else {
            // 到上限了就不响应——比弹一个 alert 温和，而且标题栏一直显示着 8/8。
            return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateTitle()
    }
}
