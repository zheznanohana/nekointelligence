#!/usr/bin/env python3
"""把面板底部两条误导性提示换成本项目的真实说明（等长替换，不足补空格）。
用法: patch_footer.py <WritingToolsViewService>
幂等: 只匹配原文；已被替换的文件再跑会报 0 处。"""
import sys
VS = sys.argv[1] if len(sys.argv) > 1 else None
if not VS:
    print("usage: patch_footer.py <WritingToolsViewService>"); sys.exit(2)
PAIRS = [
    (b"Certain capabilities are unavailable at this time. Try again later.",
     "Powered by Qwen · local bridge (unofficial)"),
    (b"Once support is downloaded, [device] will be able to use all Writing Tools capabilities.",
     "Results come from your own API provider and may contain mistakes."),
]
data = bytearray(open(VS, 'rb').read())
total = 0
for old, new in PAIRS:
    nb = new.encode()
    if len(nb) > len(old):
        print("SKIP too long:", new, len(nb), ">", len(old)); continue
    repl = nb + b" " * (len(old) - len(nb))
    n = 0; i = data.find(old)
    while i >= 0:
        data[i:i+len(old)] = repl
        n += 1; i = data.find(old, i + len(old))
    total += n
    print("patched %-70s %d occurrence(s) %d/%d bytes" % (old[:60].decode(), n, len(nb), len(old)))
open(VS, 'wb').write(data)
print("total", total)
