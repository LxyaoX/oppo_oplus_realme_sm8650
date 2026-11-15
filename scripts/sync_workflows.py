#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 data/builds.json + templates/fastbuild.yml.in 生成 6.1.x 的 fastbuild 工作流。

7 个 workflow 除了版本号/源码包/机型三处，其余 1000 多行完全一样（实测两两差 10~16 行）。
改一处要改 7 遍，漏一个就出现「57 能跑、141 报错」这种漂移。这里把差异收进
data/builds.json，模板只留一份。

用法:
    python3 scripts/sync_workflows.py                 # 生成/更新 .github/workflows/fastbuild_6.1.*.yml
    python3 scripts/sync_workflows.py --check         # 只校验是否漂移，漂移退出 1（给 CI 用）
    python3 scripts/sync_workflows.py --out-dir wf --data builds.json --template templates/fastbuild.yml.in

幂等：内容一致时不写文件，退出 0。
"""
import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PLACEHOLDERS = {
    "@@NAME@@": "name",
    "@@SUB_VERSION@@": "sub",
    "@@SRC_ZIP@@": "src_zip",
    "@@SRC_DIR@@": "src_dir",
    "@@DEVICE@@": "device",
    "@@BASE_MODEL@@": "base_model",
}


def render(template: str, entry: dict) -> str:
    out = template
    for key, field in PLACEHOLDERS.items():
        out = out.replace(key, str(entry[field]))
    # BPF 流解析器：天玑机型没有这行，占位符整行删掉（含缩进），不留空行
    block_line = "          @@BPF_STREAM_PARSER_BLOCK@@\n"
    if entry.get("bpf_stream_parser"):
        out = out.replace(block_line,
                          "          #启用  BPF 流解析器,实现高性能网络流量处理,增强网络监控和分析能力\n"
                          "          echo \"CONFIG_BPF_STREAM_PARSER=y\" >> ./common/arch/arm64/configs/gki_defconfig\n")
    else:
        out = out.replace(block_line, "")
    if "@@" in out:
        raise SystemExit("模板里还有没替换的占位符: %s" % [l for l in out.splitlines() if "@@" in l][:3])
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join(ROOT, "data", "builds.json"))
    ap.add_argument("--template", default=os.path.join(ROOT, "templates", "fastbuild.yml.in"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, ".github", "workflows"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    entries = json.load(io.open(args.data, encoding="utf-8"))
    template = io.open(args.template, encoding="utf-8").read()

    drift, written = [], 0
    for e in entries:
        text = render(template, e)
        path = os.path.join(args.out_dir, "fastbuild_6.1.%s.yml" % e["sub"])
        old = io.open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if old == text:
            print("unchanged  %s" % os.path.basename(path))
            continue
        drift.append(os.path.basename(path))
        if args.check:
            print("DRIFT      %s" % os.path.basename(path))
            continue
        os.makedirs(args.out_dir, exist_ok=True)
        io.open(path, "w", encoding="utf-8", newline="").write(text)
        written += 1
        print("written    %s" % os.path.basename(path))

    if args.check and drift:
        print("\n%d 个文件与模板不一致：先改 templates/fastbuild.yml.in 或 data/builds.json，"
              "再跑 python3 scripts/sync_workflows.py" % len(drift), file=sys.stderr)
        return 1
    print("done: %d written, %d unchanged" % (written, len(entries) - written - (len(drift) if args.check else 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
