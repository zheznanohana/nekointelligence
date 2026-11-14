#!/usr/bin/env python3
"""对 WritingToolsViewService 的 x86_64 切片打三处字节补丁。

背景：ViewService 在进程内自行判断「设备是否支持生成模型」，且这个判断写死在
Swift 代码里，读的是 dyld 共享缓存里的框架。我们不改系统文件，而是把系统的
XPC 服务复制进自己的 app bundle，然后只改这份副本。

偏移换算：fat 文件里第 0 个切片从 0x4000 开始，VA 基址 0x100000000，
所以 fat_off = 0x4000 + (VA - 0x100000000)。

用法：patch_xpc.py <app>/Contents/XPCServices/WritingToolsViewService.xpc/Contents/MacOS/WritingToolsViewService
幂等：已经补过的会跳过；字节不匹配会报错并退出，避免改坏。
"""
import sys

SLICE0_OFF = 0x4000
BASE = 0x100000000

PROLOGUE = bytes.fromhex("55 48 89 e5 41 57 41 56 41 55 41 54 53 48 81 ec")

PATCHES = [
    # gmsAvailability 访问器：返回 bitmask 0b11（available + 在线）
    ("gmsAvailability", 0x100008720, PROLOGUE, bytes.fromhex("b8 03 00 00 00 c3")),
    # isComposeModelsAvailable -> true
    ("isComposeModelsAvailable", 0x10008a560, PROLOGUE, bytes.fromhex("b0 01 c3")),
    # isComposeDisabled -> false
    ("isComposeDisabled", 0x10008b590, PROLOGUE, bytes.fromhex("31 c0 c3")),
]


def off(va: int) -> int:
    return SLICE0_OFF + (va - BASE)


def main(path: str) -> int:
    data = bytearray(open(path, "rb").read())
    changed = 0
    for name, va, orig, new in PATCHES:
        o = off(va)
        cur = bytes(data[o:o + len(orig)])
        if cur[:len(new)] == new:
            print(f"  {name:26s} 已打过")
            continue
        if cur != orig:
            print(f"  {name:26s} 字节不匹配 @0x{o:x}: {cur.hex(' ')}", file=sys.stderr)
            return 1
        data[o:o + len(new)] = new
        changed += 1
        print(f"  {name:26s} 已打补丁 @0x{o:x}")
    if changed:
        open(path, "wb").write(data)
    print(f"  合计修改 {changed} 处")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))