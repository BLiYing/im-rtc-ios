#!/usr/bin/env bash
# check-logging.sh —— 日志纪律门禁（CONVENTIONS.md §6）。
#
#   ./scripts/check-logging.sh              全量
#   ./scripts/check-logging.sh --selftest   门禁自检
#
# 为什么要有闸：姊妹项目上「禁止直接 print」这条写在规范里很久，
# 因为有兼容桥接兜底、"看起来没坏"，累计出过 54 处违规而无人察觉。
# **没有闸门的规范等于没有规范。**
#
# 三条规矩：
#   ① 业务代码禁止 print / NSLog / debugPrint —— 统一走 IMRTCLog；
#   ② 媒体回调与统计轮询里禁止日志（每帧/每包都走的路径），用 // HOTPATH-BEGIN/END 标出；
#   ③ 凭据与 SDP 不得整条打印 —— 必须过脱敏函数。
set -u

cd "$(dirname "$0")/.." || { echo "无法定位仓库根目录"; exit 2; }
CHECK_ROOT=${CHECK_ROOT:-.}

sources() {
  find "$CHECK_ROOT/Sources" -name '*.swift' 2>/dev/null | sort
}

fail=0
note() { echo "  ✗ $1"; fail=1; }

# strip_comments 把一个文件的**注释内容抹掉**，只留代码，行号照旧（输出 `行号:代码`）。
#
# 为什么要真的解析而不是 `grep -v '//'`：本仓大量用 `/** */` 写「为什么」，
# 而且块注释的正文**不带 `*` 前缀**（就是空格加正文）。于是「解释为什么禁止 NSLog」
# 这种再正常不过的注释会被当成真的调用拦下——IMErrorCode.swift 上真撞过一次。
# 只按前缀排也不行，正文长什么样都有可能，只能跟着 /* */ 的配对走。
strip_comments() {
  awk '
    {
      line = $0
      if (inblock) {
        idx = index(line, "*/")
        if (idx > 0) { line = substr(line, idx + 2); inblock = 0 } else { line = "" }
      }
      while (1) {
        s = index(line, "/*")
        if (s == 0) break
        rest = substr(line, s + 2)
        e = index(rest, "*/")
        if (e == 0) { line = substr(line, 1, s - 1); inblock = 1; break }
        line = substr(line, 1, s - 1) substr(rest, e + 2)
      }
      c = index(line, "//")
      if (c > 0) line = substr(line, 1, c - 1)
      print NR ":" line
    }
  ' "$1"
}

# ---- 自检：门禁本身是 fail-open 的闸，回归会静默放行 ----
# **先于扫描分支处理**：写在后面的话自检会跑成"扫描真仓库"，永远是绿的。
if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d) || exit 2
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Sources/X"
  cat > "$tmp/Sources/X/Bad.swift" <<'BAD'
func f() {
    print("这一行必须被拦下")
}
BAD
  if CHECK_ROOT="$tmp" "$0" >/dev/null 2>&1; then
    echo "✗ selftest 失败：门禁放行了一处 print 违规"
    exit 1
  fi
  cat > "$tmp/Sources/X/Bad.swift" <<'GOOD'
func f() {
    IMRTCLog.info("这一行是合规的")
}
GOOD
  if ! CHECK_ROOT="$tmp" "$0" >/dev/null 2>&1; then
    echo "✗ selftest 失败：门禁误报了合规代码"
    exit 1
  fi
  # 块注释里提到被禁的 API **不是**违规——解释「为什么禁 NSLog」时必然要写出这个名字。
  cat > "$tmp/Sources/X/Bad.swift" <<'DOC'
/**
 桥成 NSError 时保住 code。

 不这么做的话宿主 NSLog(@"%@", error) 打出来的是没有意义的默认值。
 */
func f() {
    IMRTCLog.info("这一行是合规的")
}
DOC
  if ! CHECK_ROOT="$tmp" "$0" >/dev/null 2>&1; then
    echo "✗ selftest 失败：门禁把块注释里提到的 NSLog 当成了真的调用"
    exit 1
  fi
  echo "✓ check-logging selftest 通过"
  exit 0
fi

echo "== 日志纪律检查 =="

echo "  [1/3] 直接打印（print / NSLog / debugPrint）"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  # 只看真正的调用：行首或非标识符字符之后紧跟函数名与左括号。
  # 注释先被 strip_comments 抹掉，所以「解释为什么禁止 NSLog」不会被算成违规。
  hits=$(strip_comments "$file" \
         | grep -E '(^|[^A-Za-z0-9_.])(print|debugPrint|NSLog)[[:space:]]*\(')
  if [ -n "$hits" ]; then
    note "$file 里有直接打印，请改用 IMRTCLog"
    echo "$hits" | head -3 | sed 's/^/      /'
  fi
done < <(sources)

echo "  [2/3] 热路径（HOTPATH-BEGIN…HOTPATH-END）里的日志调用"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  awk -v f="$file" '
    # 标记必须紧跟 //，且本行不含相反标记——否则说明性注释会被当成真标记。
    /^[[:space:]]*\/\/[[:space:]]*HOTPATH-BEGIN/ && !/HOTPATH-END/ { inhot=1; next }
    /^[[:space:]]*\/\/[[:space:]]*HOTPATH-END/   && !/HOTPATH-BEGIN/ { inhot=0; next }
    inhot && /IMRTCLog\./ { print "      " f ":" NR ": " $0; found=1 }
    END { if (found) exit 1 }
  ' "$file" || note "$file 的热路径里有日志调用——请改成原子计数器"
done < <(sources)

echo "  [3/3] 凭据与 SDP 是否过了脱敏"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if strip_comments "$file" \
     | grep -E 'IMRTCLog\.[a-z]+\([^)]*(token|roomToken|sdp|candidate)[^)]*\)' \
     | grep -viE 'redact' >/dev/null; then
    note "$file 里把凭据/SDP 直接打进了日志，请过 IMRTCLog.redact*"
    grep -nE 'IMRTCLog\.[a-z]+\([^)]*(token|roomToken|sdp|candidate)[^)]*\)' "$file" \
      | grep -viE 'redact' | head -3 | sed 's/^/      /'
  fi
done < <(sources)

echo ""
if [ "$fail" -ne 0 ]; then
  echo "结果：✗ 有违规（见 CONVENTIONS.md §6）。"
  exit 1
fi
echo "结果：✓ 全部通过。"
