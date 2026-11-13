#!/bin/bash
# 【备用通道】git push 版，要求本机 github.com:443 可达。
# 若 github.com 走代理 CONNECT 超时（本机实测如此），改用 Scripts/build_remote.sh（纯 REST API，只走 api.github.com）。
# 用法: GITHUB_TOKEN=ghp_xxx IPA_URL=https://.../original.ipa bash Scripts/push_repo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${GITHUB_TOKEN:?请先 export GITHUB_TOKEN=<你的 GitHub token>，需要 repo + workflow 权限}"
REPO_NAME="${REPO_NAME:-BleKey}"
GITHUB_REPO="${GITHUB_REPO:-}"
IPA_URL="${IPA_URL:-}"
API="https://api.github.com"

AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

echo "==> [1/5] 确认账号"
if [ -z "$GITHUB_REPO" ]; then
  LOGIN="$(curl -fsS "${AUTH[@]}" "$API/user" | python3 -c 'import json,sys;print(json.load(sys.stdin)["login"])')"
  echo "    账号: $LOGIN"
  echo "==> [2/5] 创建私有仓库 $REPO_NAME（已存在则复用）"
  curl -fsS -X POST "${AUTH[@]}" "$API/user/repos" \
    -d "{\"name\":\"$REPO_NAME\",\"private\":true,\"description\":\"Standalone BLE car key (TrollStore / iOS 16)\",\"auto_init\":false}" \
    > /dev/null 2>&1 || echo "    仓库已存在或未创建，继续用现有仓库"
  GITHUB_REPO="$LOGIN/$REPO_NAME"
else
  echo "    指定仓库: $GITHUB_REPO"
fi
echo "    target: https://github.com/$GITHUB_REPO"

echo "==> [3/5] 初始化并推送"
if [ ! -d .git ]; then git init -q; fi
git config user.name  "${GIT_NAME:-blekey-builder}"
git config user.email "${GIT_EMAIL:-blekey-builder@users.noreply.github.com}"
git checkout -B main -q 2>/dev/null || git branch -M main
git add -A
git commit -qm "BleKey: standalone BLE car key shell + extractor + TrollStore build" || echo "    无新改动，沿用上次提交"
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git push -f -u origin main
echo "    推送完成"

echo "==> [4/5] 触发 macOS 编译"
if [ -n "$IPA_URL" ]; then
  BODY="{\"ref\":\"main\",\"inputs\":{\"ipa_url\":\"$IPA_URL\",\"skip_extract\":\"false\"}}"
  echo "    附带原包直链，runner 会先跑抽取脚本"
else
  BODY='{"ref":"main","inputs":{"skip_extract":"true"}}'
  echo "    未提供原包直链，使用仓库内的 Generated/BridgeConfig.json"
fi
# push 事件本身也会触发一次 workflow，这里再手动 dispatch 一次以带上 inputs
curl -fsS -X POST "${AUTH[@]}" \
  "$API/repos/$GITHUB_REPO/actions/workflows/build-ipa.yml/dispatches" \
  -d "$BODY" > /dev/null && echo "    workflow_dispatch 已触发" || \
  echo "    dispatch 未成功（仓库可能刚创建，Actions 尚未就绪），push 触发的那次仍会跑"

echo "==> [5/5] 产物位置"
echo "    Actions 页面: https://github.com/$GITHUB_REPO/actions"
echo "    编译完成后在对应 run 的 Artifacts 里下载 BleKey-TrollStore-ipa.zip"
