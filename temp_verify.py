#!/usr/bin/env python3
"""临时自检：Vectors.directory() 的逐级查找 + scripts/test.sh 的 sibling_root()。

从仓库里的**真实源码**抽出那两段逻辑来跑（不是抄一份），源码改坏了这里跟着红。
三个修复各有专门的用例：
  - 同名普通文件不能当目录收（fileExists 要带 isDirectory）
  - 一路找不到时走到根要停（"/" 的上一级是 "/.."，不 standardized 会挂死）
  - sibling_root 的 common 不漏到全局，且 `||` 兜底仍然生效

用法：python3 temp_verify.py
"""
from __future__ import annotations

import json
import logging
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent
SERVER_CONFORMANCE = (REPO.parent / "im-rtc-server/docs/conformance").resolve()
SWIFT_TIMEOUT_S = 180  # 首次起 swift 解释器要编译；超时即视为挂死
WALK_RE = re.compile(r"^[ \t]*var dir = packageRoot\n.*?(?=^[ \t]*return fallback$)", re.S | re.M)
SIBLING_ROOT_RE = re.compile(r"^sibling_root\(\) \{\n.*?^\}$", re.S | re.M)
log = logging.getLogger("temp_verify")


@dataclass
class Result:
    name: str
    ok: bool
    detail: str


@dataclass
class WalkCase:
    name: str
    start: Path
    expect: Path | None  # None = 期望找不到（返回 nil，走 fallback）


@dataclass
class Proc:
    code: int
    stdout: str
    stderr: str


def run(cmd: list[str], cwd: Path, timeout: float) -> Proc:
    """跑子进程；超时 / 命令不存在都转成非零码，不往外抛。"""
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return Proc(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired as e:
        partial = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        return Proc(124, partial, f"TIMEOUT after {timeout}s（挂死？）")
    except OSError as e:
        return Proc(127, "", f"无法执行 {cmd[0]}: {e}")


def extract(pattern: re.Pattern[str], path: Path, what: str) -> str:
    """从源文件里抽一段代码；读不到或结构变了抛 ValueError。"""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        raise ValueError(f"读不到 {path}: {e}") from e
    m = pattern.search(text)
    if not m:
        raise ValueError(f"{path.name} 里找不到 {what}（源码结构变了？更新本脚本的正则）")
    return m.group(0)


# ── Swift：Vectors.directory() 的逐级查找 ──────────────────────────────


def build_swift_fixtures(tmp: Path) -> list[WalkCase]:
    stray = tmp / "stray/im-rtc-server/docs"
    stray.mkdir(parents=True)
    (stray / "conformance").touch()  # 同名的普通文件
    mixed_real = tmp / "mixed/im-rtc-server/docs/conformance"
    mixed_real.mkdir(parents=True)
    (tmp / "mixed/a/im-rtc-server/docs").mkdir(parents=True)
    (tmp / "mixed/a/im-rtc-server/docs/conformance").touch()
    return [
        WalkCase("主检出 → 同级 im-rtc-server", REPO, SERVER_CONFORMANCE),
        WalkCase("worktree 形状的路径 → 仍找到同级", REPO / ".claude/worktrees/x", SERVER_CONFORMANCE),
        WalkCase("近处是同名文件、远处是目录 → 跳过文件取目录", tmp / "mixed/a/pkg", mixed_real),
        WalkCase("只有同名普通文件 → 不收，返回 nil", tmp / "stray/pkg", None),
        WalkCase("一路都没有 → 走到根停下，不挂死", tmp / "empty/pkg", None),
    ]


def swift_program(walk_body: str, cases: list[WalkCase]) -> str:
    calls = "\n".join(
        f'print("=> " + (find(URL(fileURLWithPath: {json.dumps(str(c.start))}))?.path ?? "nil"))'
        for c in cases
    )
    return (
        "import Foundation\nsetvbuf(stdout, nil, _IOLBF, 0)\n"
        f"func find(_ packageRoot: URL) -> URL? {{\n{walk_body}    return nil\n}}\n{calls}\n"
    )


def judge_walk(case: WalkCase, got: str | None, proc: Proc) -> Result:
    name = f"swift: {case.name}"
    if got is None:
        return Result(name, False, f"没有输出 exit={proc.code} {proc.stderr.strip()[-300:]}")
    if case.expect is None:
        return Result(name, got == "nil", f"got {got}")
    return Result(name, got != "nil" and Path(got).resolve() == case.expect.resolve(), f"got {got}")


def check_swift_walk(tmp: Path) -> list[Result]:
    try:
        body = extract(WALK_RE, REPO / "Tests/IMCallEngineTests/Vectors.swift", "逐级查找循环")
        cases = build_swift_fixtures(tmp)
        program = tmp / "walk.swift"
        program.write_text(swift_program(body, cases), encoding="utf-8")
    except (ValueError, OSError) as e:
        return [Result("swift: 准备", False, str(e))]
    proc = run(["swift", str(program)], cwd=tmp, timeout=SWIFT_TIMEOUT_S)
    outs = [line[3:] for line in proc.stdout.splitlines() if line.startswith("=> ")]
    return [judge_walk(c, outs[i] if i < len(outs) else None, proc) for i, c in enumerate(cases)]


# ── Shell：test.sh 的 sibling_root() ─────────────────────────────────


def make_git_worktree(base: Path) -> tuple[Path, Path]:
    """临时仓 base/main，worktree 挂在 main/.claude/worktrees/x（与真实布局同形）。返回 (期望的兄弟根, worktree)。"""
    main = base / "main"
    main.mkdir(parents=True)
    ident = ["-c", "user.email=verify@local", "-c", "user.name=verify", "-c", "commit.gpgsign=false"]
    steps = [
        ["git", "init", "-q"],
        ["git", *ident, "commit", "-q", "--no-verify", "--allow-empty", "-m", "init"],
        ["git", "worktree", "add", "-q", "-b", "x", ".claude/worktrees/x"],
    ]
    for cmd in steps:
        proc = run(cmd, cwd=main, timeout=30)
        if proc.code != 0:
            raise RuntimeError(f"{' '.join(cmd)} 失败: {proc.stderr or proc.stdout}")
    return base, main / ".claude/worktrees/x"


def shell_case(fn: str, name: str, cwd: Path, expect: Path | None) -> Result:
    script = f'{fn}\nsibling_root\necho "leak=[${{common-unset}}]"'
    proc = run(["bash", "-c", script], cwd=cwd, timeout=30)
    lines = proc.stdout.strip().splitlines()
    if proc.code != 0 or len(lines) < 2:
        return Result(f"shell: {name}", False, f"exit={proc.code} out={proc.stdout!r} err={proc.stderr!r}")
    got, leak = lines[-2], lines[-1]
    path_ok = got == ".." if expect is None else Path(got).resolve() == expect.resolve()
    return Result(f"shell: {name}", path_ok and leak == "leak=[unset]", f"got {got}; {leak}")


def check_sibling_root(tmp: Path) -> list[Result]:
    try:
        fn = extract(SIBLING_ROOT_RE, REPO / "scripts/test.sh", "sibling_root()")
        nogit = tmp / "nogit"
        nogit.mkdir()
        wt_root, wt = make_git_worktree(tmp / "g")
    except (ValueError, OSError, RuntimeError) as e:
        return [Result("shell: 准备", False, str(e))]
    cases = [
        ("主检出 → 仓库的上一级", REPO, REPO.parent),
        ("worktree（绝对路径分支）→ 主检出的上一级", wt, wt_root),
        ("非 git 目录 → 退回 ..（|| 兜底仍生效）", nogit, None),
    ]
    return [shell_case(fn, name, cwd, expect) for name, cwd, expect in cases]


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    with tempfile.TemporaryDirectory(prefix="im-rtc-verify-") as d:
        tmp = Path(d).resolve()
        results = check_sibling_root(tmp) + check_swift_walk(tmp)
    for r in results:
        (log.info if r.ok else log.error)("%s %s — %s", "✓" if r.ok else "✗", r.name, r.detail)
    failed = sum(not r.ok for r in results)
    log.info("结果：%d/%d 通过", len(results) - failed, len(results))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
