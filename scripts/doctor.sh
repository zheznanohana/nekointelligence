#!/bin/bash
# doctor.sh — 自检（14 项）与自动修复
#   bash doctor.sh           只检查
#   bash doctor.sh --fix     能自动修的自动修
#
# 检查项从「能不能真的生成」倒推：补丁在不在、注入链是否指到真实文件、
# XPC 副本有没有丢 entitlements、供应商配置是否完整、中继是否在跑。
set -uo pipefail

SUP="${SUP:-$HOME/Library/Application Support/AppleIntel}"
# 安装位置以 App 自己记录的为准（默认 /Applications；老版本装在 ~/Applications）
if [ -z "${APP:-}" ]; then
  APP="$(head -n1 "$SUP/install-path.txt" 2>/dev/null || true)"
  [ -n "$APP" ] && [ -d "$APP" ] || APP="/Applications/Apple Intelligence (Intel).app"
  [ -d "$APP" ] || APP="$HOME/Applications/Apple Intelligence (Intel).app"
fi
XPC="$APP/Contents/XPCServices/WritingToolsViewService.xpc"
VS="$XPC/Contents/MacOS/WritingToolsViewService"
AI="$SUP/AI"
DO_FIX=0
[ "${1:-}" = "--fix" ] && DO_FIX=1

PASS=0; FAIL=0
# 语言：GM_LANG 环境变量 > App 设置（settings.json 里的 language）> 中文
GM_LANG="${GM_LANG:-$(grep -o '"language"[^,}]*' "$SUP/settings.json" 2>/dev/null | grep -o 'en' | head -1)}"
T() { if [ "${GM_LANG:-}" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
fixable() { printf "      \033[33m└ %s\033[0m\n" "$(T "可运行 bash doctor.sh --fix 修复" "run bash doctor.sh --fix to repair")"; }

echo "$(T "Apple 智能（Intel）自检" "Apple Intelligence (Intel) self-check")"
echo "$(T "  应用: $APP" "  App: $APP")"
echo "$(T "  支持: $SUP" "  Support: $SUP")"
echo

# 1 应用存在
[ -d "$APP" ] && ok "$(T "应用已安装" "App installed")" || { bad "$(T "应用不存在：$APP" "App not found: $APP")"; }
# 2 宿主可执行
[ -x "$APP/Contents/MacOS/AppleIntelligenceIntel" ] && ok "$(T "宿主程序可执行" "Host executable present")" || bad "$(T "宿主程序缺失" "Host executable missing")"
# 3 XPC 副本
[ -f "$VS" ] && ok "$(T "ViewService 副本存在" "ViewService copy present")" || bad "$(T "ViewService 副本缺失（重新运行 build.sh）" "ViewService copy missing (run build.sh again)")"
# 4 六个注入库
MISS=0; for n in gmhook6 gmpref gmax gmvs gmtype2 vsstub; do [ -f "$AI/$n.dylib" ] || MISS=$((MISS+1)); done
[ "$MISS" -eq 0 ] && ok "$(T "6 个注入库齐全" "All 6 injected libraries present")" || bad "$(T "缺少 $MISS 个注入库（启动一次 App 会自动补齐）" "$MISS injected libraries missing (launch the app once to restore them)")"
# 5 字节补丁
if [ -f "$VS" ]; then
  HEX=$(xxd -p -l 5 -s $((0x4000+0x8720)) "$VS" 2>/dev/null)
  [ "$HEX" = "b803000000" ] && ok "$(T "可用性补丁在位" "Availability patch in place")" || bad "$(T "可用性补丁缺失（重新 build）" "Availability patch missing (rebuild)")"
else bad "$(T "无法检查补丁" "Couldn't check the patch")"; fi
# 6 页脚文案
if [ -f "$VS" ]; then
  if grep -aq "Powered by Qwen" "$VS"; then ok "$(T "页脚文案已替换" "Panel footer replaced")"; else bad "$(T "页脚文案未替换" "Panel footer not replaced")"; fi
fi
# 7 XPC entitlements
if [ -d "$XPC" ]; then
  if codesign -d --entitlements :- "$XPC" 2>/dev/null | grep -c "generativeexperiences.textcomposition" >/dev/null; then
    ok "$(T "XPC entitlements 完整" "XPC entitlements intact")"
  else bad "$(T "XPC entitlements 被剥离（重签时不要用 --deep）" "XPC entitlements stripped (don't re-sign with --deep)")"; fixable; fi
fi
# 8 注入链有效
if [ -f "$XPC/Contents/Info.plist" ]; then
  CHAIN=$(/usr/libexec/PlistBuddy -c "Print :XPCService:EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$XPC/Contents/Info.plist" 2>/dev/null)
  GOOD=1
  IFS=':' read -ra PARTS <<< "$CHAIN"
  for p in "${PARTS[@]}"; do [ -f "$p" ] || GOOD=0; done
  [ "$GOOD" = "1" ] && [ -n "$CHAIN" ] && ok "$(T "注入链指向真实文件" "Injection chain points to real files")" || { bad "$(T "注入链失效（app 被移动后启动一次即可自愈）" "Injection chain broken (launch the app once after moving it)")"; fixable; }
fi
# 9 供应商配置
if [ -f "$SUP/providers.json" ]; then
  if python3 - "$SUP/providers.json" <<'PY'
import json,sys,urllib.parse
d=json.load(open(sys.argv[1]))
ps=d.get("providers") or []
a=d.get("active")
sel=[p for p in ps if p.get("id")==a] or ps
if not sel:
    sys.exit(1)
base=sel[0].get("base_url") or ""
host=(urllib.parse.urlparse(base).hostname or "").lower()
loopback=host in ("localhost", "127.0.0.1", "::1") or host.startswith("127.")
sys.exit(0 if base and (sel[0].get("api_key") or loopback) else 1)
PY
  then ok "$(T "供应商配置完整" "Provider configuration complete")"; else bad "$(T "供应商配置缺少 Key 或 Base URL（打开 App → 侧边栏「服务商」里填）" "Provider is missing an API key or Base URL (open the app → Providers)")"; fi
else bad "$(T "还没有 providers.json（打开 App → 侧边栏「服务商」里添加）" "No providers.json yet (open the app → Providers to add one)")"; fi
# 10 App 是否在跑（内置中继）
if pgrep -f "AppleIntelligenceIntel" >/dev/null 2>&1; then ok "$(T "App 正在运行（内置中继应已监听）" "App is running (the built-in relay should be listening)")"; else bad "$(T "App 未运行（中继随 App 启动）" "App is not running (the relay starts with the app)")"; fixable; fi
# 11 socket
if [ -S /tmp/qwen.sock ]; then ok "$(T "中继 socket 存在" "Relay socket exists")"; else bad "$(T "中继 socket 不存在" "Relay socket missing")"; fixable; fi
# 12 供应商声明（右键服务）
CNT=$(/usr/libexec/PlistBuddy -c "Print :NSServices" "$APP/Contents/Info.plist" 2>/dev/null | grep -c "NSMessage" || true)
[ "${CNT:-0}" -ge 6 ] && ok "$(T "6 项系统服务已声明" "All 6 Services declared")" || bad "$(T "系统服务声明不足（$CNT/6）" "Not all Services declared ($CNT/6)")"
# 13 pbs 缓存
if [ -f "$SUP/.pbs-flushed" ] && [ ! "$APP/Contents/Info.plist" -nt "$SUP/.pbs-flushed" ] 2>/dev/null; then
  ok "$(T "服务列表缓存已刷新" "Services cache refreshed")"
else bad "$(T "服务列表缓存可能过期" "Services cache may be stale")"; fixable; fi
# 14 LaunchServices 注册
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# 注意：pipefail 下 grep -q 提前退出会让 lsregister 收到 SIGPIPE 而误判，所以先完整读完
if "$LSR" -dump 2>/dev/null | grep -c "handleServiceRewriteInPlace" >/dev/null; then ok "$(T "LaunchServices 已注册服务" "Services registered with LaunchServices")"; else bad "$(T "LaunchServices 未注册" "Not registered with LaunchServices")"; fixable; fi

echo
echo "$(T "通过 $PASS 项，失败 $FAIL 项" "$PASS passed, $FAIL failed")"
[ "$FAIL" -eq 0 ] && exit 0

if [ "$DO_FIX" = "1" ]; then
  echo; echo "$(T "开始自动修复…" "Repairing…")"
  [ -f "$SUP/vs.entitlements" ] && [ -d "$XPC" ] && {
    codesign --force --sign - --entitlements "$SUP/vs.entitlements" "$XPC" >/dev/null 2>&1 && echo "$(T "  已重签 XPC" "  Re-signed XPC")"
    codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "$(T "  已重签 app" "  Re-signed app")"
  }
  "$LSR" -f "$APP" >/dev/null 2>&1 && echo "$(T "  已注册 LaunchServices" "  Registered with LaunchServices")"
  /System/Library/CoreServices/pbs -flush en zh-Hans >/dev/null 2>&1 && touch "$SUP/.pbs-flushed" && echo "$(T "  已刷新服务缓存" "  Refreshed Services cache")"
  if ! pgrep -f "AppleIntelligenceIntel" >/dev/null 2>&1; then
    open "$APP" 2>/dev/null && echo "$(T "  已启动 App（如提示权限请允许）" "  Launched the app (allow any permission prompts)")"
  fi
  echo; echo "$(T "修复完成，请重新运行本脚本确认。" "Repair finished. Run this script again to confirm.")"
fi
exit 1