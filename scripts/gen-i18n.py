#!/usr/bin/env python3
"""把 im-rtc-server/docs/i18n/strings.json（跨端文案表）生成成 Swift 文案表。
`demo.` 开头的 key 是 Demo 页面自己的文案，不进 SDK，单独生成到 Demo 工程的 DemoMessages.gen.swift。

  python3 scripts/gen-i18n.py          重新生成
  python3 scripts/gen-i18n.py --check  与已提交的不一致就失败（test.sh 用）
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(os.environ.get("RTC_I18N_FILE", ROOT.parent / "im-rtc-server/docs/i18n/strings.json"))
OUT = ROOT / "Sources/IMCallKit/State/IMMessages.gen.swift"
DEMO_OUT = ROOT / "Demo/IMRTCDemo/IMRTCDemo/DemoMessages.gen.swift"


def sw(s: str) -> str:
    """Swift 字符串字面量：转义 \\ " 与换行（\\( 插值也因 \\ 被转义而失效，正是想要的）。"""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def render(data: dict, demo: bool) -> str:
    locales = data["locales"]
    strings = {k: v for k, v in data["strings"].items() if k.startswith("demo.") == demo}
    for key, row in strings.items():
        for loc in locales:
            if not row.get(loc):
                sys.exit(f"✗ {key} 缺 {loc}")
    names = {"zh-CN": "zhCN", "en": "en"}
    out = ["// 由 scripts/gen-i18n.py 生成，勿手改。源：im-rtc-server/docs/i18n/strings.json", "",
           "enum DemoMessages {" if demo else "enum IMMessages {", ""]
    for loc in locales:
        out.append(f"    static let {names[loc]}: [String: String] = [")
        out += [f"        {sw(k)}: {sw(v[loc])}," for k, v in strings.items()]
        out += ["    ]", ""]
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> None:
    if not SRC.exists():
        sys.exit(f"✗ 找不到文案表：{SRC}\n  把 im-rtc-server 克隆到本仓同级，或设 RTC_I18N_FILE。")
    data = json.loads(SRC.read_text(encoding="utf-8"))
    targets = [(OUT, render(data, demo=False)), (DEMO_OUT, render(data, demo=True))]
    for path, text in targets:
        if "--check" in sys.argv:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                sys.exit(f"✗ {path.name} 与文案表不一致，跑 python3 scripts/gen-i18n.py")
        else:
            path.write_text(text, encoding="utf-8")
            print("  已生成", path.name)
    if "--check" in sys.argv:
        print("  文案表与生成物一致")


if __name__ == "__main__":
    main()
