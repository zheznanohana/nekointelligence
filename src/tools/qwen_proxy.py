#!/usr/bin/env python3
"""Unsandboxed Qwen proxy for the textcomposerd bridge.

textcomposerd runs inside an App Sandbox with network-outbound denied, but it
*can* connect to a unix socket under /tmp.  This helper does the real HTTPS
call (by literal IP with SNI pinned, since the system resolver is broken).
"""
import json, os, socket, ssl, sys, threading, time

CFG = os.environ.get("QWEN_CFG", "/tmp/tp_cfg.json")
SOCK = os.environ.get("QWEN_SOCK", "/tmp/qwen.sock")
LOG = os.environ.get("QWEN_LOG", "/tmp/qwen_proxy.log")
IPS = os.environ.get("QWEN_IPS", "39.106.104.16,39.106.80.255").split(",")
HOST = "token-plan.cn-beijing.maas.aliyuncs.com"
PATH = "/compatible-mode/v1/chat/completions"

lock = threading.Lock()
def lg(*a):
    with lock:
        with open(LOG, "a") as f:
            f.write(time.strftime("%H:%M:%S ") + " ".join(str(x) for x in a) + "\n")

cfg = json.load(open(CFG))
KEY = cfg["api_key"]
NO_THINK = True
MODEL = cfg.get("chat_model") or "qwen3.8-flash"

def https_post(body: bytes, timeout=45):
    last = None
    for ip in IPS:
        try:
            ctx = ssl.create_default_context()
            raw = socket.create_connection((ip, 443), timeout=timeout)
            s = ctx.wrap_socket(raw, server_hostname=HOST)
            hdr = (f"POST {PATH} HTTP/1.1\r\nHost: {HOST}\r\n"
                   f"Authorization: Bearer {KEY}\r\n"
                   f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
                   "Connection: close\r\n\r\n").encode()
            s.sendall(hdr + body)
            chunks = []
            while True:
                d = s.recv(65536)
                if not d: break
                chunks.append(d)
            s.close()
            raw_resp = b"".join(chunks)
            head, _, rbody = raw_resp.partition(b"\r\n\r\n")
            if b"transfer-encoding: chunked" in head.lower():
                out = bytearray(); p = 0
                while p < len(rbody):
                    nl = rbody.find(b"\n", p)
                    if nl < 0: break
                    try: sz = int(rbody[p:nl].split(b";")[0].strip(), 16)
                    except ValueError: break
                    if sz <= 0: break
                    out += rbody[nl+1:nl+1+sz]; p = nl + 1 + sz
                    while p < len(rbody) and rbody[p:p+2] == b"\r\n": p += 2
                rbody = bytes(out)
            return rbody
        except Exception as e:
            last = f"{ip}: {e}"
            lg("ip fail", last)
    raise RuntimeError(last or "no ip")


SENT_END = "。！？.!?\n"

def split_chunks(text, maxlen=700):
    out, cur = [], ""
    for ch in text:
        cur += ch
        if ch in SENT_END and len(cur) >= maxlen // 2:
            out.append(cur); cur = ""
        elif len(cur) >= maxlen:
            out.append(cur); cur = ""
    if cur:
        out.append(cur)
    # merge tiny tails
    merged = []
    for c in out:
        if merged and len(c) < 60:
            merged[-1] += c
        else:
            merged.append(c)
    return merged

def ask_chunked(system, user, temperature=0.3):
    if len(user) <= 600:
        return ask(system, user, max_tokens=max(600, len(user) // 2 + 300), temperature=temperature)
    chunks = split_chunks(user)
    lg("chunked input len=%d chunks=%d" % (len(user), len(chunks)))
    results = [None] * len(chunks)
    def work(i, c):
        for tr in range(2):
            try:
                results[i] = ask(system, c, max_tokens=max(600, len(c) + 300), temperature=temperature)
                return
            except Exception as e:
                lg("chunk %d try %d fail %r" % (i, tr + 1, e))
    ths = [threading.Thread(target=work, args=(i, c), daemon=True) for i, c in enumerate(chunks)]
    [t.start() for t in ths]
    [t.join() for t in ths]
    failed = sum(1 for r in results if r is None)
    if failed:
        lg("chunked degraded: %d/%d chunks kept original" % (failed, len(chunks)))
    return "".join(r if r else chunks[i] for i, r in enumerate(results))

def ask(system, user, max_tokens=800, temperature=0.3):
    for attempt in range(2):
        payload = {"model": MODEL, "temperature": temperature, "max_tokens": max_tokens,
                   "messages": [{"role": "system", "content": system or ""},
                                {"role": "user", "content": user or ""}]}
        if NO_THINK:
            payload["enable_thinking"] = False
            payload["chat_template_kwargs"] = {"enable_thinking": False}
        body = json.dumps(payload, ensure_ascii=False).encode()
        raw = https_post(body)
        j = json.loads(raw)
        ch = j.get("choices") or []
        if not ch: raise RuntimeError("no choices: " + raw[:200].decode("utf-8", "replace"))
        msg = ch[0].get("message") or {}
        txt = msg.get("content") or msg.get("reasoning_content") or ""
        if not txt: raise RuntimeError("empty content")
        if (ch[0].get("finish_reason") or "") == "length" and max_tokens < 8000:
            max_tokens = min(max_tokens * 2, 8000)
            lg("truncated, retry max_tokens=%d" % max_tokens)
            continue
        return txt
    return txt

def handle(c):
    try:
        buf = b""
        while not buf.endswith(b"\n"):
            d = c.recv(65536)
            if not d: return
            buf += d
        req = json.loads(buf.decode("utf-8"))
        if req.get("ping"):
            c.sendall((json.dumps({"ok": True, "pong": True}) + "\n").encode()); return
        txt = ask_chunked(req.get("system", ""), req.get("user", ""),
                          float(req.get("temperature", 0.3)))
        lg("ok userLen=%d outLen=%d" % (len(req.get("user") or ""), len(txt)))
        c.sendall((json.dumps({"ok": True, "text": txt}) + "\n").encode())
    except Exception as e:
        lg("ERR", repr(e)[:300])
        try: c.sendall((json.dumps({"ok": False, "err": repr(e)[:300]}) + "\n").encode())
        except Exception: pass
    finally:
        try: c.close()
        except Exception: pass

def main():
    try: os.unlink(SOCK)
    except FileNotFoundError: pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK); os.chmod(SOCK, 0o600); srv.listen(16)
    lg("listening", SOCK, "model", MODEL)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
