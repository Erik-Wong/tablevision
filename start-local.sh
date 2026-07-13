#!/bin/bash
# TableVision — 启动本地 OCR 桥接服务
# 前端已部署到 https://tablevision.vercel.app
# 本脚本启动本地 Vision Framework OCR 服务（端口 8765）

DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8765

# Check OCR binary
if [ ! -f "$DIR/ocr" ]; then
    echo "⚠  OCR 二进制文件不存在，正在编译…"
    swiftc -o "$DIR/ocr" "$DIR/ocr.swift" -framework Vision -framework AppKit 2>&1
    if [ $? -ne 0 ]; then
        echo "✗ 编译失败"
        exit 1
    fi
    echo "✓ 编译完成"
fi

# Kill existing process on port
EXISTING=$(lsof -ti :$PORT 2>/dev/null)
if [ -n "$EXISTING" ]; then
    echo "→ 停止已有服务 (PID $EXISTING)"
    kill -9 $EXISTING 2>/dev/null
    sleep 0.5
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       TableVision — 本地 OCR 桥接服务       ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  本地 API:  http://localhost:$PORT            ║"
echo "║  线上前端:  https://tablevision.vercel.app   ║"
echo "║                                              ║"
echo "║  打开浏览器访问线上地址即可使用              ║"
echo "║  Ctrl+C 停止服务                             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Open online URL in browser
open "https://tablevision.vercel.app" 2>/dev/null &

# Start server
cd "$DIR"
python3 server.py
