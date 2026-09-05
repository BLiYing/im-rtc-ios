#if canImport(UIKit)
import UIKit

/*
 网络质量条 ▂▄▆。草图 §03 通话中那一行「▂▄▆ 网络良好」。

 输入是 `networkQuality` 回调的 level（0~6，0 = 未知，服务端节流 2s）。
 三根柱子按 level 亮起：1~2 亮一根、3~4 两根、5~6 三根。
 **除了柱子还要有文字**——不用颜色/形状作为唯一信息载体（CONVENTIONS §8 无障碍）。
 */
public final class IMNetworkBars: UIView {

    private let bars = (0..<3).map { _ in UIView() }
    private let textLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /// apply 按 level 刷新。0 = 未知时整条隐藏，别画一个「三根全灰」让人以为网断了。
    public func apply(level: Int) {
        let theme = IMKitTheme.current
        isHidden = level <= 0
        let lit = level <= 0 ? 0 : min(3, (level + 1) / 2)
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = index < lit ? theme.accept : UIColor(white: 1, alpha: 0.25)
        }
        textLabel.text = Self.description(for: level)
        accessibilityLabel = "网络\(textLabel.text ?? "")"
    }

    private static func description(for level: Int) -> String {
        switch level {
        case 5...: return "网络良好"
        case 3...4: return "网络一般"
        case 1...2: return "网络较差"
        default: return ""
        }
    }

    private func build() {
        let barsStack = UIStackView(arrangedSubviews: bars)
        barsStack.axis = .horizontal
        barsStack.alignment = .bottom
        barsStack.spacing = 2
        for (index, bar) in bars.enumerated() {
            bar.layer.cornerRadius = 1
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            bar.heightAnchor.constraint(equalToConstant: CGFloat(5 + index * 3)).isActive = true
        }

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = IMKitTheme.current.secondaryText

        let row = UIStackView(arrangedSubviews: [barsStack, textLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        apply(level: 0)
    }
}
#endif
