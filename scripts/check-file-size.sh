#!/usr/bin/env bash
# check-file-size.sh —— 防「上帝类」体检：单个 .swift 文件行数超阈值即失败（见 CONVENTIONS.md §2）。
#
#   全量（pre-commit / CI / test.sh 第 1 步）：  ./scripts/check-file-size.sh
#   指定文件：                                   ./scripts/check-file-size.sh a.swift b.swift
#   编辑期钩子单文件（静默，仅超限时 stderr+exit 2）： ./scripts/check-file-size.sh --hook path/to/x.swift
#   门禁自检（防「fail-open 闸回归后静默放行」）：  ./scripts/check-file-size.sh --selftest
#
#   退出码 1 = 有文件超预算；2 = --hook 命中超限 / 内部错误。
#
# 阈值 600：Swift 表达力高，600 行已经很长。超标的正确处理是**拆分**，不是放宽阈值：
#   ① ViewController 膨胀 → 抽协作对象（Presenter / Layoutter / DataSource），不是堆私有方法充数。
#   ② 一个类型多个关注点   → 拆 extension 到独立文件（CallEngine+Room.swift）。
#   ③ 状态机膨胀          → 按状态族拆（CallStateMachine+Ringing.swift）。
#
# 历史欠账登记在 grandfather_limit()：值 = 登记时行数 + 少量余量，**只准降不准升**；
# 降到 MAX 以下后从表里删掉那一行。新仓请保持这张表为空。
set -u

MAX_LINES=${MAX_LINES:-600}
WARN_RATIO=${WARN_RATIO:-80}   # 达上限该比例即预警（不失败），尽早规划拆分

grandfather_limit() {
  case "$1" in
    # 目前没有历史欠账 —— 新仓，别开这个口子。
    *) echo "" ;;
  esac
}

# 测试文件不纳入体检（表驱动用例天然长）；生成代码同理。
is_skipped() {
  case "$1" in
    *Tests.swift|*Test.swift|*/Tests/*|*.generated.swift) return 0 ;;
  esac
  return 1
}

cd "$(dirname "$0")/.." || { echo "无法定位仓库根目录"; exit 2; }

limit_for() {
  local gf; gf=$(grandfather_limit "$1")
  [ -n "$gf" ] && echo "$gf" || echo "$MAX_LINES"
}

# ---- 自检：门禁本身是「fail-open」的闸，回归会静默放行超标文件 ----
if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d) || { echo "mktemp 失败"; exit 2; }
  trap 'rm -rf "$tmp"' EXIT
  fails=0
  mk() { yes 'x' | head -n "$1" > "$2"; }
  chk() { # $1=期望退出码 $2=MAX(空=默认) $3=描述 —— 其余=传给本脚本的参数
    local want="$1" maxv="$2" desc="$3"; shift 3
    local got
    if [ -n "$maxv" ]; then MAX_LINES="$maxv" "$0" "$@" >/dev/null 2>&1; else "$0" "$@" >/dev/null 2>&1; fi
    got=$?
    if [ "$got" -ne "$want" ]; then echo "  ✗ 自检失败：${desc}（期望 exit ${want}，实得 ${got}）"; fails=1
    else echo "  ✓ ${desc}"; fi
  }
  mk 10 "$tmp/small.swift"
  mk 999 "$tmp/big.swift"
  mk 999 "$tmp/BigTests.swift"
  echo "== 门禁自检 =="
  chk 0 100 "小文件放行"            "$tmp/small.swift"
  chk 1 100 "大文件拦截"            "$tmp/big.swift"
  chk 0 100 "测试文件跳过"          "$tmp/BigTests.swift"
  chk 2 100 "--hook 超限返回 2"     --hook "$tmp/big.swift"
  chk 0 100 "--hook 正常返回 0"     --hook "$tmp/small.swift"
  echo ""
  [ "$fails" -eq 0 ] && { echo "结果：✓ 门禁自检通过。"; exit 0; } || { echo "结果：✗ 门禁自身有问题，先修脚本。"; exit 1; }
fi

# ---- 编辑期钩子模式：只看一个文件，静默通过，超限写 stderr 并 exit 2 ----
if [ "${1:-}" = "--hook" ]; then
  f="${2:-}"
  [ -n "$f" ] && [ -f "$f" ] || exit 0
  case "$f" in *.swift) ;; *) exit 0 ;; esac
  is_skipped "$f" && exit 0
  lines=$(wc -l < "$f" | tr -d ' ')
  limit=$(limit_for "$f")
  if [ "$lines" -gt "$limit" ]; then
    echo "⚠ 体量超限：${f} ${lines} 行 > ${limit}。请拆分（抽协作对象 / 拆 extension 到独立文件），别放宽阈值。见 CONVENTIONS.md §2。" >&2
    exit 2
  fi
  exit 0
fi

# ---- 全量 / 指定文件 ----
fail=0; warn=0
if [ "$#" -gt 0 ]; then
  SRC=("$@")
else
  SRC=()
  scan_dirs=()
  for d in Sources Demo; do [ -d "$d" ] && scan_dirs+=("$d"); done
  if [ ${#scan_dirs[@]} -gt 0 ]; then
    while IFS= read -r line; do SRC+=("$line"); done < <(find "${scan_dirs[@]}" -name "*.swift" 2>/dev/null | sort)
  fi
fi

echo "== 单文件行数体检（默认上限 ${MAX_LINES}；历史欠账见脚本内 grandfather_limit）=="
if [ ${#SRC[@]} -eq 0 ]; then
  echo "  （没有待检查的 .swift 文件——新仓尚未落地代码）"
  echo ""
  echo "结果：✓ 全部通过。"
  exit 0
fi
for f in "${SRC[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in *.swift) ;; *) continue ;; esac
  is_skipped "$f" && continue
  lines=$(wc -l < "$f" | tr -d ' ')
  gf=$(grandfather_limit "$f")
  if [ -n "$gf" ]; then limit=$gf; tag=" [欠账·待拆]"; else limit=$MAX_LINES; tag=""; fi
  if [ "$lines" -gt "$limit" ]; then
    echo "  ✗ FAIL  ${f}  ${lines} 行 > ${limit}${tag}"
    fail=1
  else
    warn_at=$(( limit * WARN_RATIO / 100 ))
    if [ "$lines" -ge "$warn_at" ]; then
      echo "  ⚠ WARN  ${f}  ${lines} 行（≥ ${warn_at}，接近上限 ${limit}）${tag}"
      warn=1
    fi
  fi
done

echo ""
if [ "$fail" -ne 0 ]; then
  echo "结果：✗ 有文件超预算——请拆分（抽协作对象 / 拆 extension 到独立文件），不要放宽阈值。见 CONVENTIONS.md §2。"
  exit 1
fi
[ "$warn" -ne 0 ] && echo "结果：✓ 通过（有 WARN——尽早规划拆分，勿等触顶）。" || echo "结果：✓ 全部通过。"
exit 0
