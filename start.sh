#!/bin/bash
# TableVision 一键启动脚本
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "┌──────────────────────────────────────────┐"
echo "│       TableVision — 图片转表格平台       │"
echo "│       macOS Vision OCR Engine            │"
echo "└──────────────────────────────────────────┘"
echo ""

# Check OCR binary
if [ ! -f "$DIR/ocr" ]; then
    echo "⚠  编译 OCR 引擎..."
    swiftc -o "$DIR/ocr" "$DIR/ocr.swift" -framework Vision -framework AppKit 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "✗ 编译失败，请确保已安装 Xcode Command Line Tools"
        exit 1
    fi
    echo "✓ OCR 引擎编译完成"
fi

# Check frontend
if [ ! -f "$DIR/outputs/image-to-table.html" ]; then
    echo "✗ 前端文件不存在: outputs/image-to-table.html"
    exit 1
fi

# Check port
if lsof -i :8765 >/dev/null 2>&1; then
    echo "⚠  端口 8765 已被占用，尝试关闭旧进程..."
    lsof -ti :8765 | xargs kill -9 2>/dev/null
    sleep 1
fi

echo "✓ 启动服务..."
echo ""
python3 "$DIR/server.py"
