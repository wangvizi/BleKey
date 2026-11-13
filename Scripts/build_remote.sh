#!/bin/bash
# 一条命令完成：本地抽取 -> REST API 推仓库 -> macOS runner 编译 -> 取回 ipa。
# 不依赖 git push / gh CLI，只走 api.github.com。
#
# 用法:
#   # 原包放 input/ 后（推荐，自动上传）
#   GITHUB_TOKEN=ghp_xxx bash Scripts/build_remote.sh
#   # 或用直链
#   GITHUB_TOKEN=ghp_xxx IPA_URL=https://.../original.ipa bash Scripts/build_remote.sh
#   # 指定已有仓库 / 建公开仓库（macOS runner 不耗私有额度）
#   GITHUB_REPO=owner/repo GITHUB_TOKEN=xxx bash Scripts/build_remote.sh --public
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${GITHUB_TOKEN:?请先 export GITHUB_TOKEN=<token>，classic 需要 repo+workflow，fine-grained 需要 Contents/Actions/Administration 写权限}"
: "${PYTHON:=python}"

echo "==> [0/4] 本地自检"
"$PYTHON" Tools/check_repo.py || { echo "ERROR: 静态自检未通过" >&2; exit 1; }

IPA="$(find input -maxdepth 1 -iname '*.ipa' -print -quit 2>/dev/null || true)"
if [ -n "$IPA" ] && [ "${SKIP_EXTRACT:-0}" != "1" ]; then
  echo "==> [0.5/4] 从本地原包抽取接口配置"
  "$PYTHON" Tools/extract_ipa.py "$IPA" --out Generated
  echo "    配置已更新: Generated/BridgeConfig.json"
elif [ -n "${IPA_URL:-}" ]; then
  echo "==> [0.5/4] 使用原包直链，抽取由 runner 执行"
else
  echo "==> [0.5/4] 未发现原包，使用仓库内 Generated/BridgeConfig.json"
fi

echo "==> [1/4] 起远程编译"
exec "$PYTHON" Tools/gh_api.py all "$@"
