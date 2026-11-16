#!/bin/sh
# 安装 kkAgent
#   scripts/install.sh core   编译并安装核心，注册成 launchd 后台服务（开机自启、崩溃自动拉起），然后重启核心
#   scripts/install.sh app    编译并安装界面到 ~/Applications/kkAgent.app（不动核心）
#   scripts/install.sh        两个都装
#
# 核心程序放在 ~/.kkagent/bin/，和界面分开：重装界面不会碰到正在运行的核心。
set -e
cd "$(dirname "$0")/.."

LABEL=com.kk.kkagent.core
DATA="$HOME/.kkagent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${KKAGENT_PORT:-7788}"

install_core() {
  scripts/build.sh core
  mkdir -p "$DATA/bin" "$HOME/Library/LaunchAgents"
  # 先拷成临时文件再改名，正在运行的旧核心不受影响
  cp build/kkagent-core "$DATA/bin/kkagent-core.new"
  mv -f "$DATA/bin/kkagent-core.new" "$DATA/bin/kkagent-core"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DATA/bin/kkagent-core</string></array>
  <key>WorkingDirectory</key><string>$DATA</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$DATA/core.log</string>
  <key>StandardErrorPath</key><string>$DATA/core.log</string>
</dict>
</plist>
EOF

  # 重新注册：先卸掉旧的（没有也没关系），再加载。
  # 旧服务刚卸掉时可能还没完全退出，马上加载会报「Bootstrap failed: 5」，所以失败了等 1 秒再试，最多 5 次
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  registered=""
  for _ in 1 2 3 4 5; do
    if bootstrap_error=$(launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>&1); then registered=1; break; fi
    sleep 1
  done
  if [ -z "$registered" ]; then
    # 留下最后一次的报错：区分是旧服务没退干净，还是配置真有问题
    echo "✗ 注册后台服务失败（最后一次报错：${bootstrap_error}），手动执行：launchctl bootstrap gui/$(id -u) $PLIST"
    exit 1
  fi

  # 等核心起来
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf --noproxy '*' "http://127.0.0.1:$PORT/api/health" >/dev/null; then
      # 变量后面紧跟中文时要写成 ${PORT}，否则 sh 会把全角字符的字节当成变量名的一部分
      echo "✓ 核心已在后台运行：http://127.0.0.1:${PORT}（日志 ${DATA}/core.log）"
      return
    fi
    sleep 1
  done
  echo "✗ 核心 10 秒内没起来，看日志：tail -n 30 $DATA/core.log"
  exit 1
}

install_app() {
  scripts/build.sh app
  mkdir -p "$HOME/Applications"
  # 界面正在运行的话先退出，避免拷贝时文件被占用
  pkill -f "kkAgent.app/Contents/MacOS/kkAgentApp" 2>/dev/null || true
  # 等旧界面真正退出（最多 5 秒）：没退干净就 open，系统会报 -600 打不开
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "kkAgent.app/Contents/MacOS/kkAgentApp" >/dev/null || break
    sleep 0.5
  done
  rm -rf "$HOME/Applications/kkAgent.app"
  cp -R build/kkAgent.app "$HOME/Applications/kkAgent.app"
  # 装完重新打开（上面把正在运行的关掉了，不打开的话要用户自己再点一次）
  open "$HOME/Applications/kkAgent.app"
  echo "✓ 界面已安装并打开：~/Applications/kkAgent.app"
}

case "${1:-all}" in
  core) install_core ;;
  app)  install_app ;;
  all)  install_core; install_app ;;
  *)    echo "用法：scripts/install.sh [core|app]"; exit 1 ;;
esac
