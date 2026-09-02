#!/usr/bin/env bash
# install-hooks.sh —— 把版本库内的 scripts/hooks 设为本仓 git 钩子目录。
# 每个 clone 跑一次即可（core.hooksPath 是本机 .git/config，不随代码走）。
#
#   用法：./scripts/install-hooks.sh
#   卸载：git config --unset core.hooksPath
set -eu

cd "$(dirname "$0")/.."

git config core.hooksPath scripts/hooks
chmod +x scripts/hooks/* 2>/dev/null || true

echo "✓ 已设 core.hooksPath = scripts/hooks"
echo "  pre-commit 生效：每次 commit 前自动跑 scripts/check-file-size.sh。"
echo "  绕过单次提交：git commit --no-verify"
