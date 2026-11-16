#!/bin/sh
# 管理后台核心
#   scripts/core.sh status    看核心在不在、pid、端口
#   scripts/core.sh restart   重启核心（中转会话会冷启动一次，投递中的消息会标记失败）
#   scripts/core.sh stop      停掉核心（launchd 不会再拉起，直到 start 或重新安装）
#   scripts/core.sh start     启动核心
#   scripts/core.sh log       实时看日志
LABEL=com.kk.kkagent.core
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${KKAGENT_PORT:-7788}"
TARGET="gui/$(id -u)/$LABEL"

case "$1" in
  status)
    if curl -sf --noproxy '*' "http://127.0.0.1:$PORT/api/health"; then echo; else echo "核心没有响应（端口 $PORT）"; fi
    launchctl print "$TARGET" 2>/dev/null | grep -E "state|pid|last exit" || echo "launchd 里没有注册核心，先运行 scripts/install.sh core"
    ;;
  restart) launchctl kickstart -k "$TARGET" && echo "已重启" ;;
  stop)    launchctl bootout "$TARGET" && echo "已停止" ;;
  start)   launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl kickstart "$TARGET"; echo "已启动" ;;
  log)     tail -n 50 -f "$HOME/.kkagent/core.log" ;;
  *)       echo "用法：scripts/core.sh status|restart|stop|start|log"; exit 1 ;;
esac
