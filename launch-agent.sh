#!/bin/bash
# TableVision — LaunchAgent 后台启动脚本
# 由 ~/Library/LaunchAgents/com.tablevision.ocr.plist 调用
# 登录时自动启动，崩溃后自动重启

DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8765
LOG_FILE="$HOME/Library/Logs/tablevision.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

log "======== TableVision LaunchAgent 启动 ========"
log "工作目录: $DIR"

# Check OCR binary
if [ ! -f "$DIR/ocr" ]; then
    log "OCR 二进制文件不存在，正在编译…"
    swiftc -o "$DIR/ocr" "$DIR/ocr.swift" -framework Vision -framework AppKit 2>>"$LOG_FILE"
    if [ $? -ne 0 ]; then
        log "ERROR: OCR 编译失败"
        exit 1
    fi
    log "OCR 编译完成"
fi

# Check frontend
if [ ! -f "$DIR/outputs/image-to-table.html" ]; then
    log "ERROR: 前端文件不存在: $DIR/outputs/image-to-table.html"
    exit 1
fi

# Kill existing process on port
EXISTING=$(lsof -ti :$PORT 2>/dev/null)
if [ -n "$EXISTING" ]; then
    log "停止已有服务 (PID $EXISTING)"
    kill -9 $EXISTING 2>/dev/null
    sleep 0.5
fi

log "启动 TableVision 本地 OCR 服务 (端口 $PORT)…"

cd "$DIR"
exec /opt/homebrew/bin/python3 "$DIR/server.py" 2>>"$LOG_FILE"
