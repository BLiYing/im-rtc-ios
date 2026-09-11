#!/usr/bin/env python3
"""临时自检：SDK 版本统一 1.0.0 + 设置页「关于」四行 + 三个开关持久化。

纯静态检查：读仓库里的**真实源码**做文本断言，源码改坏了这里跟着红。
编译是否通过交给 scripts/test.sh；持久化与界面是否真的生效要真机点一遍，这里验不了。

用法：python3 temp_verify.py
"""
from __future__ import annotations

import json
import logging
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent
DEMO = REPO / "Demo/IMRTCDemo/IMRTCDemo"
EXPECTED_VERSION = "1.0.0"
VERSION_FILE = REPO / "Sources/IMCallEngine/Facade/IMCallEngineVersion.swift"
FACADE_FILE = REPO / "Sources/IMCallEngine/Facade/IMCallEngine.swift"
SIGNAL_FILE = REPO / "Sources/IMCallEngine/Signaling/SignalConnection.swift"
KIT_FILE = REPO / "Sources/IMCallKit/KitEntry.swift"
FACTORY_FILE = REPO / "Sources/IMCallEngineWebRTC/IMPeerConnections.swift"
SETTINGS_FILE = DEMO / "SettingsViewController.swift"
SESSION_FILE = DEMO / "DemoSession.swift"
OBJC_FILE = DEMO / "IMObjCAPICheck.m"
RESOLVED_FILE = REPO / "Package.resolved"
SCAN_DIRS = ("Sources", "Tests", "Demo")
SCAN_SUFFIXES = {".swift", ".m", ".h", ".plist", ".pbxproj"}
SKIP_PARTS = {".build", "DerivedData", "xcuserdata"}
# 前后不能挨着数字或点——否则 127.0.0.1 也会被当成版本号
STALE_VERSION_RE = re.compile(r"(?<![\d.])0\.0\.1(?![\d.])")
SDK_LITERAL_RE = re.compile(r'"ios/\d')
ABOUT_RE = re.compile(r"private var about: .*?\n    \}\n", re.S)
LOGIN_RE = re.compile(r"func login\(server:.*?\n    \}\n", re.S)
# 属性名 → DemoSession 里的 key 常量名
SWITCH_KEYS = {"bannerFirst": "bannerKey", "floatingWindow": "floatingKey", "verboseLog": "verboseKey"}
ABOUT_NAMES = ["SDK", "libwebrtc", "视频编码", "设备 ID"]
log = logging.getLogger("temp_verify")


@dataclass
class Result:
    name: str
    ok: bool
    detail: str


class SourceError(Exception):
    """源文件读不到或结构变了（该更新本脚本的正则）。"""


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise SourceError(f"读不到 {path.relative_to(REPO)}: {e}") from e


def section(pattern: re.Pattern[str], path: Path, what: str) -> str:
    m = pattern.search(read(path))
    if not m:
        raise SourceError(f"{path.name} 里找不到 {what}（源码结构变了？）")
    return m.group(0)


def scan_files() -> list[Path]:
    files: list[Path] = []
    for d in SCAN_DIRS:
        root = REPO / d
        if not root.is_dir():
            continue
        files += [p for p in root.rglob("*") if p.is_file() and p.suffix in SCAN_SUFFIXES
                  and not SKIP_PARTS.intersection(p.parts)]
    return files


def grep(pattern: re.Pattern[str], files: list[Path]) -> list[str]:
    hits: list[str] = []
    for f in files:
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as e:
            hits.append(f"{f.relative_to(REPO)}: 读不到（{e}）")
            continue
        hits += [f"{f.relative_to(REPO)}:{i}" for i, line in enumerate(lines, 1) if pattern.search(line)]
    return hits


# ── 版本号：单一来源 ────────────────────────────────────────────────


def check_version_constant() -> Result:
    text = read(VERSION_FILE)
    defs = grep(re.compile(r"\blet IMCallEngineVersion\b"), scan_files())
    ok = f'public let IMCallEngineVersion = "{EXPECTED_VERSION}"' in text and len(defs) == 1
    return Result("版本常量 IMCallEngineVersion = 1.0.0 且只定义一次", ok, f"定义处 {defs}")


def check_version_consumers() -> Result:
    problems: list[str] = []
    if 'public var sdk: String = "ios/\\(IMCallEngineVersion)"' not in read(SIGNAL_FILE):
        problems.append("SignalConnection 的 sdk 缺省值没用常量")
    if "public let IMCallKitVersion = IMCallEngineVersion" not in read(KIT_FILE):
        problems.append("IMCallKitVersion 没引用 Engine 常量")
    if "options.sdk =" in read(FACADE_FILE):
        problems.append("IMCallEngine 门面仍在覆写 options.sdk")
    if "IMCallEngine.sdkVersion" not in read(OBJC_FILE):
        problems.append("IMObjCAPICheck.m 没调 sdkVersion")
    literals = grep(SDK_LITERAL_RE, scan_files())
    if literals:
        problems.append(f'仍有 "ios/<数字>" 字面量 {literals}')
    return Result("sdk 字段 / Kit 版本 / ObjC 门面都取自常量", not problems, "; ".join(problems) or "ok")


def check_no_stale_version() -> Result:
    hits = grep(STALE_VERSION_RE, scan_files())
    return Result("Sources/Tests/Demo 无残留 0.0.1", not hits, f"命中 {hits}" if hits else "ok")


# ── 设置页「关于」 ──────────────────────────────────────────────────


def check_about_rows() -> Result:
    block = section(ABOUT_RE, SETTINGS_FILE, "about 列表")
    names = re.findall(r'\("([^"]+)",', block)
    problems: list[str] = []
    if names != ABOUT_NAMES:
        problems.append(f"行名 {names} ≠ {ABOUT_NAMES}")
    if '"im-rtc-ios \\(IMCallKitVersion)"' not in block:
        problems.append("SDK 行没用 IMCallKitVersion")
    if not re.search(r"H\.264.*VP8", block):
        problems.append("视频编码行缺 H.264 优先 / VP8 回落")
    if "about.count" not in read(SETTINGS_FILE):
        problems.append("行数没跟 about.count 走")
    return Result("关于 = SDK / libwebrtc / 视频编码 / 设备 ID 四行", not problems, "; ".join(problems) or "ok")


def resolved_webrtc_version() -> str:
    try:
        pins = json.loads(read(RESOLVED_FILE)).get("pins", [])
    except json.JSONDecodeError as e:
        raise SourceError(f"Package.resolved 不是合法 JSON: {e}") from e
    for pin in pins:
        if pin.get("identity") == "webrtc":
            return str(pin.get("state", {}).get("version", ""))
    raise SourceError("Package.resolved 里没有 webrtc 这一条")


def check_libwebrtc_matches_lock() -> Result:
    version = resolved_webrtc_version()
    expect = f"M{version.split('.')[0]}（stasel/WebRTC {version}）"
    ok = f'"{expect}"' in section(ABOUT_RE, SETTINGS_FILE, "about 列表")
    return Result("libwebrtc 行与 Package.resolved 锁定版本一致", ok, f"锁定 {version}，期望文案 {expect}")


# ── 三个开关持久化 ─────────────────────────────────────────────────


def check_switch_keys() -> Result:
    text = read(SESSION_FILE)
    problems: list[str] = []
    for prop, key in SWITCH_KEYS.items():
        if f'private static let {key} = "im-rtc-demo.{prop}"' not in text:
            problems.append(f"{prop}: 缺 key 常量")
        if not re.search(rf"UserDefaults\.standard\.set\(\w+, forKey: Self\.{key}\)", text):
            problems.append(f"{prop}: 没写盘")
        if not re.search(rf"object\(forKey: (Self|DemoSession)\.{key}\) as\? Bool", text):
            problems.append(f"{prop}: 启动没读回")
    if not re.search(r"var verboseLog: Bool = .*\?\? true", text):
        problems.append("verboseLog 缺省值不是 true")
    return Result("三个开关都有 UserDefaults key、写盘且启动读回", not problems, "; ".join(problems) or "ok")


def check_log_level_wiring() -> Result:
    login = section(LOGIN_RE, SESSION_FILE, "login(server:username:)")
    settings = read(SETTINGS_FILE)
    problems: list[str] = []
    if "setLevel(.debug)" in login or "setLevel(logLevel)" not in login:
        problems.append("login 里的日志级别没用存下的值")
    if re.search(r"\bvar verbose\b", settings) or "IMRTCLog.setLevel" in settings:
        problems.append("设置页仍自己持有 verbose / 自己调 setLevel")
    if "kitConfig" in settings:
        problems.append("设置页绕过 DemoSession 直接改 kitConfig")
    for prop in SWITCH_KEYS:
        if f"self.session.{prop} = $0" not in settings:
            problems.append(f"设置页 {prop} 没经 DemoSession 写")
    return Result("日志级别与开关读写一律经 DemoSession", not problems, "; ".join(problems) or "ok")


def check_factory_comment() -> Result:
    text = read(FACTORY_FILE)
    old = "// 软编解码工厂：**VP8 是 MVP 基线**"
    ok = old not in text and "IMUplinkPolicy.preferH264Codec" in text
    return Result("编码器工厂注释已改（引 Android 分析，不再称 VP8 基线）", ok, "ok" if ok else "旧注释仍在或缺出处")


CHECKS: list[Callable[[], Result]] = [
    check_version_constant, check_version_consumers, check_no_stale_version,
    check_about_rows, check_libwebrtc_matches_lock,
    check_switch_keys, check_log_level_wiring, check_factory_comment,
]


def run_check(fn: Callable[[], Result]) -> Result:
    try:
        return fn()
    except SourceError as e:
        return Result(fn.__name__, False, str(e))


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    results = [run_check(fn) for fn in CHECKS]
    for r in results:
        (log.info if r.ok else log.error)("%s %s — %s", "✓" if r.ok else "✗", r.name, r.detail)
    failed = sum(not r.ok for r in results)
    log.info("结果：%d/%d 通过", len(results) - failed, len(results))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
