#!/bin/bash
# build.sh — 从源码组装出可分发的 .app 与 .dmg
#
# 设计原则：仓库里不包含任何 Apple 的二进制。构建时从本机系统复制一份
# WritingToolsViewService.xpc 到 app bundle 内，只改这份副本（字节补丁），
# 并把我们自己的注入库与宿主程序装进去。
#
# 用法：
#   ./scripts/build.sh                 # 构建到 /Applications/… 并顺手生成 DMG
#   APP_OUT=/tmp/Test.app NO_DMG=1 ./scripts/build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP_OUT:-/Applications/Apple Intelligence (Intel).app}"
DIST="${DIST:-$HERE/dist}"
EXE="AppleIntelligenceIntel"
BUNDLE_ID="com.local.appleintelligence.intel"
SUP="${SUP:-$HOME/Library/Application Support/AppleIntel}"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
SYS_VS="/System/Library/PrivateFrameworks/WritingToolsUI.framework/Versions/A/XPCServices/WritingToolsViewService.xpc"

say() { printf "\033[1m==> %s\033[0m\n" "$*"; }
die() { printf "\033[31m错误: %s\033[0m\n" "$*" >&2; exit 1; }

command -v clang >/dev/null || die "需要 Xcode Command Line Tools（xcode-select --install）"
command -v python3 >/dev/null || die "需要 python3"
[ -d "$SYS_VS" ] || die "找不到 $SYS_VS —— 这台机器上没有 Apple Intelligence 的系统组件？"

say "构建目标: $APP"
# 同一个 App 只留一份：默认安装时清掉老位置 ~/Applications 里的旧副本，并让正在运行的实例退出
OLD="$HOME/Applications/Apple Intelligence (Intel).app"
if [ -z "${APP_OUT:-}" ]; then
  pkill -f "Apple Intelligence (Intel).app/Contents/MacOS/" 2>/dev/null || true
  [ -d "$OLD" ] && [ "$OLD" != "$APP" ] && rm -rf "$OLD" && echo "  已移除旧位置的副本: $OLD"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AI" "$APP/Contents/Resources/support" \
         "$APP/Contents/XPCServices" "$APP/Contents/AI"

say "1/6 复制系统 WritingToolsViewService（Apple 二进制不随仓库分发）"
cp -R "$SYS_VS" "$APP/Contents/XPCServices/"
VS="$APP/Contents/XPCServices/WritingToolsViewService.xpc/Contents/MacOS/WritingToolsViewService"
[ -f "$VS" ] || die "复制后找不到 ViewService 二进制"

say "2/6 打字节补丁（可用性 + 文案）"
python3 "$HERE/scripts/patch_xpc.py" "$VS"
python3 "$HERE/scripts/patch_footer.py" "$VS"

say "3/6 编译注入库"
cc -dynamiclib -O1 -Wno-deprecated-declarations -o "$APP/Contents/Resources/AI/gmhook6.dylib" \
   "$HERE/src/inject/gmhook6.c" -framework CoreFoundation \
   -L"$SDK/usr/lib/system" -lxpc -lsystem_eligibility -L"$SDK/usr/lib" -lMobileGestalt
cc -dynamiclib -O1 -o "$APP/Contents/Resources/AI/gmpref.dylib" \
   "$HERE/src/inject/gmpref.c" -framework CoreFoundation
cc -dynamiclib -O1 -fobjc-arc -o "$APP/Contents/Resources/AI/gmvs.dylib" \
   "$HERE/src/inject/gmvs.m" -framework Cocoa
cc -dynamiclib -O1 -fobjc-arc -o "$APP/Contents/Resources/AI/gmax.dylib" \
   "$HERE/src/inject/gmax.m" -framework Cocoa
cc -dynamiclib -O1 -fobjc-arc -o "$APP/Contents/Resources/AI/gmtype2.dylib" \
   "$HERE/src/inject/gmtype2.m" -framework Cocoa
cc -dynamiclib -O1 -fobjc-arc -o "$APP/Contents/Resources/AI/vsstub.dylib" \
   "$HERE/src/inject/vsstub.m" -framework Foundation -framework Cocoa -framework Security -framework CFNetwork
for f in "$APP/Contents/Resources/AI/"*.dylib; do codesign --force --sign - "$f" >/dev/null 2>&1 || true; done

say "4/6 编译宿主程序（含内置中继与管理界面）"
clang -fobjc-arc -O1 -Wno-arc-performSelector-leaks -Wno-deprecated-declarations \
  -o "$APP/Contents/MacOS/$EXE" \
  "$HERE/src/host/AIHost.m" "$HERE/src/host/GMBridge.m" "$HERE/src/host/GMShell.m" "$HERE/src/host/GMSetup.m" "$HERE/src/host/GMLang.m" \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework Security

say "5/6 写 Info.plist 与支持文件"
python3 - "$APP" "$HERE" "$BUNDLE_ID" "$EXE" <<'PY'
import json, os, plistlib, sys
app, here, bundle_id, exe = sys.argv[1:5]
tpl = os.path.join(here, "scripts/templates")
def load(name):
    d = json.load(open(os.path.join(tpl, name)))
    def sub(o):
        if isinstance(o, str): return o.replace("__APP__", app)
        if isinstance(o, list): return [sub(x) for x in o]
        if isinstance(o, dict): return {k: sub(v) for k, v in o.items()}
        return o
    return sub(d)
main = load("main.json")
main["CFBundleIdentifier"] = bundle_id
main["CFBundleExecutable"] = exe
plistlib.dump(main, open(os.path.join(app, "Contents/Info.plist"), "wb"))
xpc = load("xpc.json")
plistlib.dump(xpc, open(os.path.join(app, "Contents/XPCServices/WritingToolsViewService.xpc/Contents/Info.plist"), "wb"))
print("  Info.plist 已写入")
PY
cp "$HERE/scripts/doctor.sh" "$HERE/scripts/uninstall.sh" "$HERE/scripts/probe_latency.py" \
   "$HERE/scripts/patch_footer.py" "$HERE/scripts/vs.entitlements" "$APP/Contents/Resources/support/"
[ -f "$HERE/README.md" ] && cp "$HERE/README.md" "$APP/Contents/Resources/support/README.md"
cp "$HERE/README.md" "$APP/Contents/Resources/support/使用说明.md" 2>/dev/null || true
[ -f "$HERE/assets/AppIcon.icns" ] && cp "$HERE/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf '%s\n' "$APP" > "$APP/Contents/Resources/install-path.txt"
[ -z "${APP_OUT:-}" ] && { mkdir -p "$SUP"; printf '%s\n' "$APP" > "$SUP/install-path.txt"; }

say "6/6 签名（先 XPC 带 entitlements，再 app；绝不使用 --deep）"
ENT="$HERE/scripts/vs.entitlements"
codesign --force --sign - --entitlements "$ENT" "$APP/Contents/XPCServices/WritingToolsViewService.xpc"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "  签名校验通过"

# 安装运行时支持（自检/卸载脚本、entitlements 备份、干净 plist）
mkdir -p "$SUP" "$SUP/AI" /tmp/bridge
cp "$HERE/scripts/doctor.sh" "$HERE/scripts/uninstall.sh" "$HERE/scripts/probe_latency.py" "$SUP/"
cp "$ENT" "$SUP/vs.entitlements"
cp "$APP/Contents/XPCServices/WritingToolsViewService.xpc/Contents/Info.plist" "$SUP/info-pristine.plist"
chmod +x "$SUP/doctor.sh" "$SUP/uninstall.sh" 2>/dev/null || true

# 注册系统服务（右键「服务」菜单）并刷新缓存
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSR" ] && "$LSR" -f "$APP" >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -flush en zh-Hans >/dev/null 2>&1 || true
touch "$SUP/.pbs-flushed"

# 迁移：旧版用 python 代理，已经不需要了
launchctl bootout "gui/$(id -u)/com.local.appleintel.qwenproxy" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/com.local.appleintel.qwenproxy.plist"

say "完成：$APP"

if [ "${NO_DMG:-0}" != "1" ]; then
  say "生成 DMG"
  rm -rf "$DIST"; mkdir -p "$DIST"
  cp -R "$APP" "$DIST/"
  ln -s /Applications "$DIST/Applications"
  cat > "$DIST/安装说明.txt" <<'TXT'
Apple 智能（Intel）— 非官方本地前端 + 自带 API 后端

安装：双击左侧 App，点「安装」即可（会自动复制到「应用程序」并重新打开）；
      也可以手动把它拖到右侧 Applications 文件夹。
首次打开：如果提示无法验证开发者，右键 App → 打开（本地签名、未做公证）。
首次运行会请求「辅助功能」权限（用于读取任意 App 里的选中文字），
请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选它。
之后打开 App，在左侧「服务商」里填入你自己的 API Key（⌘, 直达）。

要求：macOS 15+（本机 26.7 实测），Intel 优先（Apple Silicon 上补丁偏移不适用）；
需要关闭 SIP 与 AMFI（本方案会加载一份打过补丁的系统 XPC 服务副本）。
TXT
  DMG="$DIST/Apple-Intelligence-Intel.dmg"
  # 先做可写映像，设成「挂载即打开窗口」，再压缩成只读 UDZO
  RW="$(mktemp -d)/rw.dmg"
  hdiutil create -volname "Apple 智能 (Intel)" -srcfolder "$DIST" -ov -format UDRW "$RW" >/dev/null
  MNT="$(hdiutil attach -nobrowse -noautoopen "$RW" | tail -1 | cut -f3-)"
  if [ -n "$MNT" ]; then
    bless --folder "$MNT" --openfolder "$MNT" 2>/dev/null || true
    hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
  fi
  hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >/dev/null
  rm -rf "$(dirname "$RW")"
  echo "  DMG: $DMG ($(du -h "$DMG" | cut -f1))"
fi

cat <<EOF

下一步：
  1. open "$APP"
  2. 侧边栏「服务商」（⌘,）填写 Base URL / API Key / 模型，点「测试连接」
  3. 任意 App 里选中文字 → ⌘9（或右键 → 服务 → 直接改写选中文字）
  4. 出问题先跑：bash "$SUP/doctor.sh"
EOF