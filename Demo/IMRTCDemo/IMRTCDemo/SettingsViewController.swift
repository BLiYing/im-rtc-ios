import UIKit
import IMCallEngine
import IMCallKit

/*
 设置（草图 §02-D）：**这一屏其实是 Kit 配置项清单**。
 开关直接改 `IMCallKitConfig`——它是引用类型，Kit 下次换形态时就读到新值，不用重启。

 草图里那个「使用 Kit 整套 UI / 自画 UI」的总开关**这里没有**：iOS Demo 目前只走
 用法 B（Kit）。用法 A 在 Web Demo 里已经完整示范过一遍，iOS 这边等回调表稳定后再补。
 */
final class SettingsViewController: UITableViewController {

    private let session = DemoSession.shared

    private struct Row {
        let title: String
        let detail: String
        let isOn: () -> Bool
        let set: (Bool) -> Void
    }

    private lazy var rows: [Row] = [
        Row(title: "来电先出横幅", detail: "关掉则来电直接全屏",
            isOn: { self.session.kitConfig.bannerFirst },
            set: { self.session.kitConfig.bannerFirst = $0 }),
        Row(title: "悬浮窗", detail: "允许把通话收成悬浮球",
            isOn: { self.session.kitConfig.floatingWindow },
            set: { self.session.kitConfig.floatingWindow = $0 }),
        Row(title: "详细日志", detail: "debug 级别，含主讲人/网络质量的周期事件",
            isOn: { self.verbose },
            set: { on in
                self.verbose = on
                IMRTCLog.setLevel(on ? .debug : .info)
            }),
    ]
    private var verbose = true

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "s")
    }

    /*
     画质档位。**这是宿主策略，不是服务端下发的**（见 IMVideoProfile 的说明）：
     真实宿主从自己的配置接口拿这个值，「后台可控」在产品上就是这个意思。
     放在设置页里是为了让这条边界在 Demo 里看得见。
    */
    private let profiles = IMVideoProfile.presets

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Kit 可配项"
        case 1: return "采集画质（宿主策略，换了要重登）"
        default: return "关于"
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return rows.count
        case 1: return profiles.count
        default: return 2
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "s", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .none
        cell.accessoryType = .none
        switch indexPath.section {
        case 0:
            let row = rows[indexPath.row]
            content.text = row.title
            content.secondaryText = row.detail
            let toggle = UISwitch()
            toggle.isOn = row.isOn()
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case 1:
            let profile = profiles[indexPath.row]
            content.text = profile.name
            content.secondaryText = "\(profile.width)×\(profile.height) · \(profile.frameRate)fps · "
                + "\(profile.maxBitrateBps / 1000) kbps"
            cell.accessoryView = nil
            cell.accessoryType = profile.name == session.videoProfile.name ? .checkmark : .none
            cell.selectionStyle = .default
        default:
            content.text = indexPath.row == 0 ? "SDK" : "设备 ID"
            content.secondaryText = indexPath.row == 0 ? "im-rtc-ios 0.0.1" : session.deviceID
            cell.accessoryView = nil
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        session.videoProfile = profiles[indexPath.row]
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    @objc private func toggled(_ toggle: UISwitch) {
        rows[toggle.tag].set(toggle.isOn)
    }
}
