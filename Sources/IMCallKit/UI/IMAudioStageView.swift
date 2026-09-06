#if canImport(UIKit)
import UIKit

/*
 语音通话页与拨出中页的中间区块（规范 §03 · §04 红线）：96 头像 + 22 名字 + 13 状态 + 网络胶囊。
 拨出中头像外面多一圈**呼吸光环**（3pt，1.6s 循环，接通立刻停）。
 */
public final class IMAudioStageView: UIView {

    private let avatar = IMAvatarDiscView()
    private let ring = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let netChip = UIView()
    private let netBars = IMNetworkBars()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /**
     apply 刷新。`isRinging` 为真时光环呼吸。

     - Parameter showsCaption: 名字与状态这一行要不要显示。
       **接通之后不显示**：那时候标题栏里已经是「对方名字 + 计时器」，中间再写一遍
       就是同一句话在一屏里出现两次，还各走各的计时。呼叫中 / 来电页的标题栏是空的，
       名字与状态只在那两屏出现。
    */
    public func apply(uid: String, name: String, status: String, isRinging: Bool,
                      networkLevel: Int, showsCaption: Bool = true) {
        avatar.apply(key: uid, name: name, size: IMKitTheme.current.avatarLarge)
        nameLabel.text = name
        statusLabel.text = status
        nameLabel.isHidden = !showsCaption
        statusLabel.isHidden = !showsCaption
        netChip.isHidden = networkLevel <= 0
        netBars.apply(level: networkLevel)
        setRinging(isRinging)
    }

    private func setRinging(_ ringing: Bool) {
        ring.isHidden = !ringing
        let key = "imrtc.breathe"
        if ringing, ring.layer.animation(forKey: key) == nil {
            let breathe = CABasicAnimation(keyPath: "borderColor")
            breathe.fromValue = UIColor(white: 1, alpha: 0.25).cgColor
            breathe.toValue = UIColor(white: 1, alpha: 0.05).cgColor
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ring.layer.add(breathe, forKey: key)
        } else if !ringing {
            ring.layer.removeAnimation(forKey: key)
        }
    }

    private func build() {
        let theme = IMKitTheme.current
        let size = theme.avatarLarge
        // 光环：3pt 外环，offset 8（规范 §04）。
        ring.layer.borderWidth = 3
        ring.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        ring.layer.cornerRadius = (size + 22) / 2
        ring.isUserInteractionEnabled = false

        nameLabel.font = .systemFont(ofSize: 22, weight: .bold)
        nameLabel.textColor = theme.primaryText
        nameLabel.textAlignment = .center
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = theme.secondaryText
        statusLabel.textAlignment = .center

        netChip.backgroundColor = theme.controlBackground
        netChip.layer.cornerRadius = 10
        netBars.translatesAutoresizingMaskIntoConstraints = false
        netChip.addSubview(netBars)

        let column = UIStackView(arrangedSubviews: [avatar, nameLabel, statusLabel, netChip])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 6
        column.setCustomSpacing(14, after: avatar)

        for view in [ring, column] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: size),
            avatar.heightAnchor.constraint(equalToConstant: size),
            ring.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: size + 22),
            ring.heightAnchor.constraint(equalToConstant: size + 22),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            netChip.heightAnchor.constraint(equalToConstant: 20),
            netBars.leadingAnchor.constraint(equalTo: netChip.leadingAnchor, constant: 9),
            netBars.trailingAnchor.constraint(equalTo: netChip.trailingAnchor, constant: -9),
            netBars.centerYAnchor.constraint(equalTo: netChip.centerYAnchor),
        ])
    }
}
#endif
