#!/bin/sh
# 轻阅 Lite —— 一键推到 GitHub（iSH / macOS / Linux 都能跑）
#
# 做法：不是重新 git init + force push（那会把你 v1.4 的历史抹掉），
#       而是先接上远端、把 HEAD 对准远端 main，再把改动作为一个新提交推上去。
#       历史保留，只多一个 v1.5 提交。
#
# 用法（iSH）：
#   cd ~/qrlite && unzip 轻阅Lite-v1.5-发现页修复.zip && cd qireaderlite && sh 推.sh
#
set -e
cd "$(dirname "$0")"

REMOTE_URL="${REMOTE_URL:-ssh://git@ssh.github.com:443/806927125/qireaderlite.git}"
MSG="${MSG:-v1.5 发现页修复：ruleExplore 空时回退 ruleSearch / exploreUrl 支持 JSON 数组 / bookSourceUrl 带 ## 时切后缀}"

echo "============================================"
echo "  轻阅 Lite —— 推送到 GitHub"
echo "  远端: $REMOTE_URL"
echo "============================================"
echo

if [ ! -d .git ]; then
  echo "[1/4] 初始化本地仓库…"
  git init -q
else
  echo "[1/4] 已有本地仓库，跳过初始化"
fi

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_URL"

echo "[2/4] 接远端历史…"
if git fetch -q --depth=50 origin main 2>/dev/null; then
  # 把 HEAD 对准远端 main，但**保留工作区文件**
  git reset --soft origin/main
  echo "      已对齐 origin/main（历史保留）"
else
  echo "      ⚠️ 取不到远端 main，按新仓库处理（会覆盖远端）"
fi

echo "[3/4] 提交改动…"
git add -A
if git diff --cached --quiet; then
  echo "      没有新改动，跳过提交"
else
  git -c user.email="push@local" -c user.name="push" commit -q -m "$MSG"
  echo "      已提交"
fi

echo "[4/4] 推送到远端…"
set +e
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30" \
  git push origin HEAD:main 2>&1 | tail -6
RC=$?
set -e

echo
echo "============================================"
if [ $RC -eq 0 ]; then
  echo "  ✅ 推送完成"
  echo
  echo "  出 IPA（挑一个）："
  echo "   A. GitHub Actions（免费）"
  echo "      https://github.com/806927125/qireaderlite/actions/workflows/build-ipa.yml"
  echo "      点「Run workflow」→ 等 3~5 分钟 → Artifacts 下载"
  echo
  echo "   B. Codemagic（免费 500 分钟/月）"
  echo "      https://codemagic.io → GitHub 登录 → Add application → Start build"
  echo
  echo "  Actions 跑完后 IPA 也会被塞进 ipa-build 分支："
  echo "   https://github.com/806927125/qireaderlite/blob/ipa-build/out/QingYue.ipa"
else
  echo "  ❌ 推送失败，看上面的报错"
  echo "     常见原因："
  echo "       · iSH 没配 SSH 密钥 → 先在 iSH 里跑一次 ssh -T git@github.com"
  echo "       · 端口 443 被挡 → 把远端换成 ssh://git@github.com/806927125/qireaderlite.git"
  echo "       · 远端有别的提交 → 先 git pull --rebase origin main"
fi
echo "============================================"
exit 0
