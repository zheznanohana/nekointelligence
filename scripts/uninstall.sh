#!/bin/bash
# 彻底卸载「Apple 智能（Intel）」。
#   ./uninstall.sh          删除全部（应用 / 代理服务 / 支持目录 / 临时文件 / 偏好 / 服务注册）
#   ./uninstall.sh --check  只检查，不动任何东西
#   ./uninstall.sh --keep-data  保留配置与日志（只停服务、删应用和注入件）
set -u
SUP="$HOME/Library/Application Support/AppleIntel"
# 安装位置以 App 自己记录的为准（默认 /Applications；老版本装在 ~/Applications）
if [ -z "${APP:-}" ]; then
  APP="$(head -n1 "$SUP/install-path.txt" 2>/dev/null || true)"
  [ -n "$APP" ] && [ -d "$APP" ] || APP="/Applications/Apple Intelligence (Intel).app"
  [ -d "$APP" ] || APP="$HOME/Applications/Apple Intelligence (Intel).app"
fi
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
MODE="${1:-}"

found=0
say(){ printf '%s\n' "$*"; }
chk(){ [ -e "$1" ] && { say "  有: $1"; found=$((found+1)); }; }

if [ "$MODE" = "--check" ]; then
  say "== 已安装项 =="
  chk "$APP"
  chk "$HOME/Library/LaunchAgents/com.local.appleintel.qwenproxy.plist"
  chk "$HOME/Library/LaunchAgents/com.local.appleintel.host.plist"
  chk "$SUP"
  chk /tmp/qwen.sock
  chk /tmp/bridge
  pgrep -f "Apple Intelligence (Intel).app/Contents/MacOS" >/dev/null && { say "  运行中: 宿主应用"; found=$((found+1)); }
  pgrep -f "Apple Intelligence (Intel).app/Contents/XPCServices" >/dev/null && { say "  运行中: ViewService"; found=$((found+1)); }
  pgrep -f "AppleIntel/qwen_proxy.py" >/dev/null && { say "  运行中: 千问代理"; found=$((found+1)); }
  say "== 检查结束，命中 $found 项 =="
  exit 0
fi

say "1) 停止进程"
launchctl bootout gui/501/com.local.appleintel.host 2>/dev/null
launchctl bootout gui/501/com.local.appleintel.qwenproxy 2>/dev/null
pkill -f "Apple Intelligence (Intel).app/Contents/MacOS" 2>/dev/null
pkill -f "Apple Intelligence (Intel).app/Contents/XPCServices" 2>/dev/null
pkill -f "AppleIntel/qwen_proxy.py" 2>/dev/null
sleep 1

say "2) 移除登录项 / 后台代理"
rm -f "$HOME/Library/LaunchAgents/com.local.appleintel.qwenproxy.plist"
rm -f "$HOME/Library/LaunchAgents/com.local.appleintel.host.plist"

say "3) 注销系统服务菜单并删除应用"
[ -d "$APP" ] && "$LSREG" -u "$APP" 2>/dev/null
rm -rf "$APP"

if [ "$MODE" = "--keep-data" ]; then
  say "4) 保留支持目录: $SUP"
else
  say "4) 删除支持目录（含 API key 配置与日志）"
  rm -rf "$SUP"
fi

say "5) 清理运行时残留"
rm -f /tmp/qwen.sock
rm -rf /tmp/bridge
rm -f /tmp/gmax*.log /tmp/gmhook*.log /tmp/gmvs*.log /tmp/gmpref*.log /tmp/gmt2.log /tmp/gmax*.dylib
rm -f /tmp/host_*.png /tmp/host_*.log /tmp/host_t*.png /tmp/vs_cap_*.png /tmp/vsstub_*.png
rm -f /tmp/ip_*.png /tmp/iphost*.out
rm -f /tmp/tp_cfg.json /tmp/long.txt /tmp/mid.txt /tmp/big.txt /tmp/cn3*.txt /tmp/clip_*.txt

say "6) 删除本工具留下的偏好"
for f in com.local.appleintel.intel com.local.appleintel.qwenproxy com.local.aihost com.local.aihost2 com.local.wthost com.local.textedit.ai; do
  defaults delete "$f" 2>/dev/null
  rm -f "$HOME/Library/Preferences/$f.plist"
done

say ""
say "完成。系统文件（/System）从未被修改，SIP / AMFI / SSV 设置也未改动。"
say "若 Finder 里仍能看到服务菜单项，注销再登录一次即可刷新。"
