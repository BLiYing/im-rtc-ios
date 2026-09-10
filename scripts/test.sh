#!/usr/bin/env bash
# test.sh —— 本仓唯一测试入口。全绿才能说「完成」（CONVENTIONS.md §9）。
#
#   ./scripts/test.sh                                 全量
#   BUILD_ONLY=1 ./scripts/test.sh                    只编译
#   RTC_CONFORMANCE_DIR=/path ./scripts/test.sh       向量不在同级目录时
#
# **别手拼 xcodebuild 命令行**：姊妹项目上踩过这条——命令行参数漂移导致
# 「本地过了 CI 挂」。要跑什么就写进这个脚本。
#
# 顺序是有意的：先跑最便宜的门禁，再编译，最后跑测试——
# 让「文件长到 800 行」这种问题在两秒内暴露，而不是等编译跑完。
#
# 注意：这里跑的是 **macOS 上的 swift test**，不需要模拟器。
# 协议层、状态机与信令都不碰 UIKit、不碰 libwebrtc，所以它们能这么跑；
# 媒体链路的验收是**真机**，那部分不在这个脚本里（CONVENTIONS §9）。
#
# 真服务端联调（`LiveServerTests`）默认以 XCTSkip 跳过，手动跑：
#   cd ../im-rtc-server && ./scripts/dev.sh
#   RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests
# 它测的是网络连通性不是协议一致性——后者由向量在每次回归里守着，不靠它。
set -u

cd "$(dirname "$0")/.." || { echo "无法定位仓库根目录"; exit 2; }

# sibling_root 打印**兄弟仓所在的那一级目录**（本仓与 im-rtc-server 同级）。
#
# **不能直接用 `..`。** 从 worktree（`.claude/worktrees/<分支>/`）里跑时，
# `..` 是 worktrees 目录，兄弟仓根本不在那儿——症状是「缺 call_fsm.json」，
# 而人会以为是没克隆 im-rtc-server。
#
# `git rev-parse --git-common-dir` 无论在主检出还是 worktree 里，都指向**共享的那个 .git**；
# 它的上一级就是主检出，再往上才是同级目录。**两种返回形态都要接住**：
# 在主检出里它给相对路径 `.git`，在 worktree 里给绝对路径。
# 不是 git 仓（打包分发的源码）时退回 `..`，与从前的行为一致。
sibling_root() {
  # local 单独一行：写成 `local common=$(…)` 时 `||` 看到的是 local 的返回码（恒 0），兜底永远不走。
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || { echo ".."; return; }
  case "${common}" in
    /*) echo "$(dirname "${common}")/.." ;;
    *)  echo "$(cd "$(dirname "${common}")" && pwd)/.." ;;
  esac
}

failed=()
step_no=0

run_step() {
  local name="$1"; shift
  step_no=$((step_no + 1))
  echo ""
  echo "──[$step_no] $name ──────────────────────────────"
  if "$@"; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name"
    failed+=("$name")
    return 1
  fi
  return 0
}

# 一致性向量在 im-rtc-server 仓里，**本仓只读引用，不拷贝**。
# 找不到时明确报错而不是跳过——被静默跳过的一致性测试比没有测试更糟。
check_conformance_available() {
  local dir="${RTC_CONFORMANCE_DIR:-$(sibling_root)/im-rtc-server/docs/conformance}"
  # 把解析结果**传下去**：`swift test` 自己也要读向量，让它和这一步用同一个答案，
  # 免得「闸门说找得到、测试说找不到」。（Android 交给 gradle、web 交给 vitest，同一做法。）
  [ -d "${dir}" ] && export RTC_CONFORMANCE_DIR="$(cd "${dir}" && pwd)"
  if [ -d "$dir" ]; then
    echo "  向量目录：$dir"
    return 0
  fi
  echo "  ✗ 找不到一致性向量目录：$dir"
  echo "    把 im-rtc-server 克隆到本仓同级，或设 RTC_CONFORMANCE_DIR。"
  echo "    **不要拷贝一份向量到本仓**——一拷贝就会漏同步。"
  return 1
}

echo "== im-rtc-ios 全量回归 =="

run_step "单文件体量门禁" ./scripts/check-file-size.sh
run_step "日志纪律门禁" ./scripts/check-logging.sh
run_step "shell 可移植性门禁" ./scripts/check-shell-portability.sh
# 闸门自己回归成 fail-open 会静默放行，所以每次回归都自检一次。
run_step "门禁自检" ./scripts/check-file-size.sh --selftest
run_step "门禁自检（日志）" ./scripts/check-logging.sh --selftest
run_step "门禁自检（shell）" ./scripts/check-shell-portability.sh --selftest
run_step "一致性向量可达" check_conformance_available
run_step "swift build" swift build

# swift test + **用例数对账**。
#
# 为什么要对账：源码里 `func testXxx` 的数量必须等于「实际执行 + 显式跳过」。
# 对不上就说明有用例**根本没被跑到**——最常见的原因是整个测试文件挂在
# `#if canImport(UIKit)` 里，而这一步跑在 macOS 上，于是它安静地贡献 0 个用例。
# 这类假绿比失败可怕得多：面板全绿，而那部分代码从来没被验过。
# （真踩过：ProfileResolverTests 第一版就是这样，7 个用例一个没跑。）
swift_test_with_census() {
  local log; log=$(mktemp)
  swift test 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  [ "$status" -eq 0 ] || { rm -f "$log"; return "$status"; }

  # 声明数：去重后统计（同名用例在不同类里各算一个，故连类名一起去重不现实，
  # 这里按「函数名去重」——足够抓住整文件被跳过这种量级的差异）。
  local declared executed skipped
  declared=$(grep -rho "func test[A-Za-z0-9_]*" Tests/ | sort -u | wc -l | tr -d ' ')
  executed=$(grep -oE "Executed [0-9]+ tests" "$log" | tail -1 | grep -oE "[0-9]+")
  skipped=$(grep -oE "with [0-9]+ test[s]? skipped" "$log" | tail -1 | grep -oE "[0-9]+")
  rm -f "$log"
  : "${executed:=0}"; : "${skipped:=0}"

  if [ "$declared" -ne "$((executed + skipped))" ]; then
    echo ""
    echo "  ✗ 用例数对不上：源码声明 ${declared}，实际执行 ${executed} + 跳过 ${skipped}"
    echo "    有用例没被跑到。最常见原因：整个测试文件挂在 #if canImport(UIKit) 下，"
    echo "    而这一步跑在 macOS 上——它会安静地贡献 0 个用例，面板照样全绿。"
    return 1
  fi
  echo "  用例数对账：声明 ${declared} = 执行 ${executed} + 跳过 ${skipped} ✓"
  return 0
}

if [ "${BUILD_ONLY:-}" != "1" ]; then
  run_step "swift test（含用例数对账）" swift_test_with_census
fi

# Demo 为 iOS 编译。**不启动模拟器**——`generic/platform=iOS Simulator` 是只编译不跑。
#
# 为什么值得多花这半分钟：上面的 swift test 跑在 macOS 上，验不到三件事——
#   · **Kit 的界面代码编不编得过**。它们全在 `#if canImport(UIKit)` 里，
#     macOS 上整个被编译器跳过——`swift build` 全绿完全不代表它们是好的。
#     Demo 依赖 IMCallKit，所以这一步顺带把它们编了一遍。
#   · Demo 还编不编得过（改了公开 API 而 Demo 没跟上，今天是没人会发现的）；
#   · **公开面对 ObjC 到底可不可用**。Demo 里的 IMObjCAPICheck.m 从 ObjC 调一遍
#     公开 API，编译即验证（CONVENTIONS §4）。它已经抓到过一个真问题：
#     `setMuted(_:_:)` 两个参数都不带标签，生成的选择器是 `setMuted::completionHandler:`。
#
# 没装 Xcode 就跳过（比如 CI 上只跑 SwiftPM 的那种机器），不算失败。
demo_builds_for_ios() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "  跳过：这台机器没有 xcodebuild"
    return 0
  fi
  xcodebuild -project Demo/IMRTCDemo/IMRTCDemo.xcodeproj -scheme IMRTCDemo \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${DEMO_DERIVED_DATA:-.build/demo-dd}" \
    build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | head -20
  return "${PIPESTATUS[0]}"
}

if [ "${SKIP_DEMO_BUILD:-}" != "1" ]; then
  run_step "Demo 为 iOS 编译（含 Kit 与 ObjC 可用性检查）" demo_builds_for_ios
fi

echo ""
echo "════════════════════════════════════════════════"
if [ ${#failed[@]} -eq 0 ]; then
  echo "结果：✓ 全绿（$step_no 步）"
  exit 0
fi
echo "结果：✗ ${#failed[@]} 步失败："
printf '  · %s\n' "${failed[@]}"
exit 1
