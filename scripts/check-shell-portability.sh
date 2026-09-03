#!/usr/bin/env bash
# check-shell-portability.sh —— shell 脚本的可移植性体检。
#
#   ./scripts/check-shell-portability.sh              全量
#   ./scripts/check-shell-portability.sh --selftest   门禁自检
#
# 目前只查一条，但这条实打实地把本地开发环境搞挂过：
#
#   **`$VAR` 后面紧跟非 ASCII 字符**（中文、全角括号…）。
#   macOS 自带的是 bash 3.2（2007 年），在 UTF-8 locale 下它会把多字节字符的
#   首字节当成变量名的一部分：`$ADDR` 后面直接跟一个全角括号时，变量名会连成
#   `$ADDR` 加上那个括号的首字节，
#   于是 `set -u` 直接报 unbound variable，脚本一行都跑不动。
#
#   要命的是它**跟 locale 有关**：LC_CTYPE=C 的环境（很多 CI、也包括某些 agent
#   的执行环境）完全正常，开发者本机的 en_US.UTF-8 就炸。写的人自己测不出来。
#
#   解法只是加对花括号：`${ADDR}（日志`。
set -u

cd "$(dirname "$0")/.." || { echo "无法定位仓库根目录"; exit 2; }
CHECK_ROOT=${CHECK_ROOT:-.}

# 变量名后紧跟一个高位字节（>= 0x80，也就是任何非 ASCII 字符的首字节）。
#
# **字节类必须用 printf 造出真实字节**：`grep -E` 不认 `\xNN` 转义，
# 写成 '[\xC2-\xF4]' 会被当成字面量集合 {x,C,2..\,F,4}，
# 于是 `$MAX_LINES` 这种大写变量名全被误报。（这个门禁自己第一版就是这么错的。）
PATTERN=$(printf '\\$[A-Za-z_][A-Za-z0-9_]*[\200-\377]')

scan() {
  find "$CHECK_ROOT" -name '*.sh' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null \
    | sort | while IFS= read -r f; do
        LC_ALL=C grep -nE "$PATTERN" "$f" 2>/dev/null | sed "s|^|${f}:|"
      done
}

# ---- 自检：门禁本身是 fail-open 的闸，回归会静默放行 ----
# **先于扫描分支处理**：写在后面的话自检会跑成「扫描真仓库」，永远是绿的。
if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d) || exit 2
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/scripts"
  # 坏样本用 printf 的 %s 拼出来：**这个文件自己不能含有那段坏写法**，
  # 否则门禁扫到自己就永远是红的（而它必须能扫自己）。
  printf 'echo "起服务 $ADDR%s"\n' '（日志 x）' > "$tmp/scripts/bad.sh"
  if CHECK_ROOT="$tmp" "$0" >/dev/null 2>&1; then
    echo "✗ selftest 失败：门禁放行了一处未加花括号的变量"
    exit 1
  fi
  printf 'echo "起服务 ${ADDR}%s"\n' '（日志 x）' > "$tmp/scripts/bad.sh"
  if ! CHECK_ROOT="$tmp" "$0" >/dev/null 2>&1; then
    echo "✗ selftest 失败：门禁误报了合规写法"
    exit 1
  fi
  echo "✓ check-shell-portability selftest 通过"
  exit 0
fi

echo "== shell 可移植性体检（\$VAR 紧跟非 ASCII）=="
hits=$(scan)
if [ -n "$hits" ]; then
  echo "$hits" | sed 's/^/  ✗ /'
  echo ""
  echo "结果：✗ 上面这些 \$VAR 后面紧跟了非 ASCII 字符。"
  echo "  macOS 的 bash 3.2 在 UTF-8 locale 下会把它们连成一个变量名，脚本直接报"
  echo "  unbound variable。加对花括号即可：\$ADDR 紧跟全角括号 → 写成 \${ADDR}"
  exit 1
fi
echo "结果：✓ 全部通过。"
