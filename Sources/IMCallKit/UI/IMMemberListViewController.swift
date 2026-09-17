#if canImport(UIKit)
import UIKit

/**
 只读的成员列表（MEETING_ROOM_DESIGN §4.6），半屏。

 # M2 只做只读的这一半

 搜索框与「正在说话」排序移出了 M2（§2.3）：25 人时列表一屏多一点就够翻，
 而成员列表在 M5（主持人操作）还要重做一次——那时才会长出「⋯」菜单里的
 静音 / 移出 / 设为主持人。现在放一个搜索框进去，等于为一个马上要重做的界面
 先付一次三端的工。

 排序：**自己 → 进房顺序**。进房顺序就是 `state.participants` 的顺序
 （`onUserEnter` 依次追加），不走画廊第一页那套发言人优先——
 列表里的人跟着说话跳位置，比画廊里更难找人。
 */
final class IMMemberListViewController: UIViewController {

    private let members: [IMParticipant]
    private let selfMicOn: Bool
    private let selfCameraOn: Bool
    private let resolver: IMProfileResolving?
    private let table = UITableView(frame: .zero, style: .plain)

    init(members: [IMParticipant], selfMicOn: Bool, selfCameraOn: Bool,
         resolver: IMProfileResolving?) {
        self.members = members
        self.selfMicOn = selfMicOn
        self.selfCameraOn = selfCameraOn
        self.resolver = resolver
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = IMKitTheme.current
        view.backgroundColor = theme.overlayBackground
        title = "成员（\(members.count + 1)）"

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.allowsSelection = false
        table.register(IMMemberCell.self, forCellReuseIdentifier: IMMemberCell.reuseID)
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            table.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension IMMemberListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count + 1 // 自己恒在第一行
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // swiftlint:disable:next force_cast
        let cell = tableView.dequeueReusableCell(withIdentifier: IMMemberCell.reuseID,
                                                 for: indexPath) as! IMMemberCell
        if indexPath.row == 0 {
            cell.apply(name: "我", avatar: nil, micOn: selfMicOn, cameraOn: selfCameraOn)
            return cell
        }
        let member = members[indexPath.row - 1]
        cell.apply(name: imResolvedName(resolver, uid: member.uid, fallback: member.uid),
                   avatar: imResolvedAvatar(resolver, uid: member.uid),
                   micOn: member.hasAudio, cameraOn: member.hasVideo)
        return cell
    }
}

/// 一行：头像 + 名字 + 麦克风 / 摄像头状态。关着的那个变暗而不是消失——位置固定，一眼扫得出来。
private final class IMMemberCell: UITableViewCell {
    static let reuseID = "IMMemberCell"

    private let avatar = IMAvatarDiscView()
    private let nameLabel = UILabel()
    private let micIcon = UIImageView()
    private let cameraIcon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let theme = IMKitTheme.current
        nameLabel.font = .systemFont(ofSize: 14)
        nameLabel.textColor = theme.primaryText
        for icon in [micIcon, cameraIcon] {
            icon.tintColor = theme.secondaryText
            icon.contentMode = .scaleAspectFit
            icon.setContentHuggingPriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [avatar, nameLabel, micIcon, cameraIcon])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            micIcon.widthAnchor.constraint(equalToConstant: 16),
            cameraIcon.widthAnchor.constraint(equalToConstant: 16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    func apply(name: String, avatar image: UIImage?, micOn: Bool, cameraOn: Bool) {
        nameLabel.text = name
        avatar.apply(key: name, name: name, size: 28, image: image)
        micIcon.image = (micOn ? IMKitIcon.mic : IMKitIcon.micSlash).image(pointSize: 13)
        cameraIcon.image = (cameraOn ? IMKitIcon.video : IMKitIcon.videoSlash).image(pointSize: 13)
        micIcon.alpha = micOn ? 1 : 0.35
        cameraIcon.alpha = cameraOn ? 1 : 0.35
        micIcon.accessibilityLabel = micOn ? "麦克风开" : "麦克风关"
        cameraIcon.accessibilityLabel = cameraOn ? "摄像头开" : "摄像头关"
    }
}
#endif
