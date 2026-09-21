#!/usr/bin/env python3
"""把 im-rtc-server/docs/i18n/strings.json（跨端文案表）生成成 Swift 文案表。

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


def sw(s: str) -> str:
    """Swift 字符串字面量：转义 \\ " 与换行（\\( 插值也因 \\ 被转义而失效，正是想要的）。"""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def render(data: dict) -> str:
    locales, strings = data["locales"], data["strings"]
    for key, row in strings.items():
        for loc in locales:
            if not row.get(loc):
                sys.exit(f"✗ {key} 缺 {loc}")
    names = {"zh-CN": "zhCN", "en": "en"}
    out = ["// 由 scripts/gen-i18n.py 生成，勿手改。源：im-rtc-server/docs/i18n/strings.json", "",
           "enum IMMessages {", ""]
    for loc in locales:
        out.append(f"    static let {names[loc]}: [String: String] = [")
        out += [f"        {sw(k)}: {sw(v[loc])}," for k, v in strings.items()]
        out += ["    ]", ""]
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> None:
    if not SRC.exists():
        sys.exit(f"✗ 找不到文案表：{SRC}\n  把 im-rtc-server 克隆到本仓同级，或设 RTC_I18N_FILE。")
    text = render(json.loads(SRC.read_text(encoding="utf-8")))
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            sys.exit("✗ IMMessages.gen.swift 与文案表不一致，跑 python3 scripts/gen-i18n.py")
        print("  文案表与生成物一致")
    else:
        OUT.write_text(text, encoding="utf-8")
        print("  已生成", OUT.name)


if __name__ == "__main__":
    main()
