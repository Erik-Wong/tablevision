#!/bin/bash
# TableVision — 一键部署到 GitHub Pages
# 使用方法: 
#   1. 先在 GitHub 创建仓库: https://github.com/new (名称: tablevision)
#   2. 运行: ./deploy-github.sh
#   3. 在 GitHub 仓库 Settings → Pages 中选择 gh-pages 分支

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="${1:-git@github.com:erikvercel/tablevision.git}"

echo "╔══════════════════════════════════════════╗"
echo "║   TableVision — GitHub Pages 部署       ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "→ 目标仓库: $REPO_URL"
echo ""

cd "$DIR"

# Check if remote exists
if git remote get-url origin &>/dev/null; then
    echo "→ 远程仓库已配置: $(git remote get-url origin)"
else
    echo "→ 添加远程仓库…"
    git remote add origin "$REPO_URL"
fi

echo "→ 推送 main 分支…"
git push -u origin main

echo "→ 推送 gh-pages 分支…"
git push -u origin gh-pages

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✓ 部署完成！                           ║"
echo "║                                          ║"
echo "║  接下来:                                 ║"
echo "║  1. 打开 GitHub 仓库 Settings → Pages    ║"
echo "║  2. Source 选择: Deploy from a branch    ║"
echo "║  3. Branch 选择: gh-pages → / (root)     ║"
echo "║  4. 保存后等待 1-2 分钟                  ║"
echo "║                                          ║"
echo "║  访问地址:                               ║"
echo "║  https://erikvercel.github.io/tablevision║"
echo "╚══════════════════════════════════════════╝"
