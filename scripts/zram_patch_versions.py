#!/usr/bin/env python3
"""打印 zram_patch 里两个补丁携带的库版本（从补丁的 + 行解析）。

用法: zram_patch_versions.py <zram_patch 目录>
输出两行：lz4 版本、zstd 版本；解析不到时输出 "?"。
"""
import io
import os
import re
import sys

MACROS = (("001-lz4.patch", "LZ4_VERSION"), ("002-zstd.patch", "ZSTD_VERSION"))


def parse(path, macro):
    try:
        text = io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return "?"
    got = {}
    # 补丁里这些行是整文件新增（+），也会出现在上下文里；两种都接受，最后一次生效
    for m in re.finditer(r"^[+ ]\s*#\s*define\s+%s_(MAJOR|MINOR|RELEASE)\s+(\d+)" % macro,
                         text, re.M):
        got[m.group(1)] = m.group(2)
    if len(got) != 3:
        return "?"
    return "%s.%s.%s" % (got["MAJOR"], got["MINOR"], got["RELEASE"])


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "zram_patch"
    for name, macro in MACROS:
        print("%s  %s" % (parse(os.path.join(d, name), macro), name))


if __name__ == "__main__":
    main()
