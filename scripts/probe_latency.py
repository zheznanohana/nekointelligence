#!/usr/bin/env python3
"""代理往返延迟探针：成功且 <10s 退出 0，否则退出 1。"""
import socket, json, time, sys, os
SOCK = "/tmp/qwen.sock"
if not os.path.exists(SOCK):
    print("socket missing"); sys.exit(1)
t = time.time()
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(20); s.connect(SOCK)
    s.sendall((json.dumps({"system": "Reply with the single word OK.",
                           "user": "ping", "max_tokens": 8}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        d = s.recv(65536)
        if not d: break
        buf += d
    s.close()
    j = json.loads(buf.decode("utf-8", "replace"))
    dt = time.time() - t
    ok = bool(j.get("ok")) and bool(j.get("text"))
    print("%.2fs ok=%s" % (dt, ok))
    sys.exit(0 if (ok and dt < 10) else 1)
except Exception as e:
    print("probe error: %r" % (e,)); sys.exit(1)
