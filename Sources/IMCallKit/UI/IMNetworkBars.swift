#if canImport(UIKit)
import UIKit

/*
 网络质量条（规范 §05 `net-bars`）：三根柱子，1~2 三根亮、3~4 两根、5~6 一根；**0 = 未知时整条隐藏**，
 别画一个「三根全灰」让人以为网断了。分档在 `imNetworkBarsLit` / `imNetworkText`（纯函数，有单测）。

 **除了柱子还要有文字**——不用颜色/形状作为唯一信息载体（CONVENTIONS §8 无障碍）。
 `compact` 模式只画柱子（格子角标里没地方放字），文字进 accessibilityLabel。
 */
public final class IMNetworkBars: UIView {

    private let bars = (0..<3).map { _ in UIView() }
    private let textLabel = UILabel()
    private let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        build()
    }

    public override convenience init(frame: CGRect) {
        self.init(compact: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /// apply 按 level 刷新。
    public func apply(level: Int) {
        let theme = IMKitTheme.current
        isHidden = level <= 0
        let lit = imNetworkBarsLit(level: level)
        // 5 以上是「网络很差」，柱子变橙（规范 §02 warn）。
        let litColor = level >= 5 ? theme.warning : theme.primaryText
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = index < lit ? litColor : UIColor(white: 1, alpha: 0.25)
        }
        textLabel.text = imNetworkText(level: level)
        textLabel.textColor = level >= 5 ? theme.warning : theme.secondaryText
        accessibilityLabel = imNetworkText(level: level)
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

        textLabel.font = .systemFont(ofSize: 11)
        textLabel.textColor = IMKitTheme.current.secondaryText
        textLabel.isHidden = compact

        let row = UIStackView(arrangedSubviews: compact ? [barsStack] : [barsStack, textLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 5
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
