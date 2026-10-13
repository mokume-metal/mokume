#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""#1862 の試作専用。main へマージしない。

先に swift build --build-tests -c release -Xswiftc -enable-testing を行う。
実行: python3 scripts/probe-unit-sphere-1862.py {compatibility|performance|validation|setupCost|all}

MOKUME_SPHERE_OUTPUT: CSV・生の画素・PNG の出力先 (既定 /private/tmp/mokume-sphere-1862/results)
MOKUME_SPHERE_SCENES: 例 light,shadow,alpha,stroke,retained,transform,zero,unit
MOKUME_SPHERE_DETAIL: 細かさ (既定24)。追加場面 orbit,ortho,random,add,replace,mixed も選べる。
MOKUME_SPHERE_CONTROL=1: 比較の両側を従来方式にする。
MOKUME_SPHERE_REFERENCE: main版で作った出力先。compatibility終了後に全ビットを照合し、
差があれば比較記録を保存して終了コード2。試作内の2経路が一致してもmainとの一致とは限らない。

GPU 枠は排他、待ちは180秒、各実行全体は600秒。期限超過では自分のプロセス群だけを終了する。
performance は各標本で GPU 完了を待つ。ライブ表示 FPS や GPU 単体時間を測るものではない。
"""
import argparse
import csv
import json
import struct
import os
from pathlib import Path
import signal
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("phase", choices=["compatibility", "performance", "validation", "setupCost", "all"])
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = Path(os.environ.get("MOKUME_SPHERE_OUTPUT", "/private/tmp/mokume-sphere-1862/results")).resolve()
out.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["MOKUME_SPHERE_OUTPUT"] = str(out)
env["MOKUME_GPU_SLOT_WAIT"] = "180"
phases = ["compatibility", "performance", "validation"] if args.phase == "all" else [args.phase]
for phase in phases:
    selected = ("(ShaderInterfaceTests|SolidShaderTests|SolidBackFaceOrderTests|RetainedSolidStrokeTests|UnitSpherePrototypeTests/isolatedRouting)"
                if phase == "validation" else f"UnitSpherePrototypeTests/{phase}")
    command = [sys.executable, "scripts/gpu-slot.py", "--exclusive", "--", "swift", "test",
               "--skip-build", "-c", "release", "-Xswiftc", "-enable-testing", "--filter", selected,
               "--xunit-output", str(out / f"{phase}.xml")]
    with (out / f"{phase}.log").open("w") as log:
        child = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=600)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            code = 124
    print(f"{phase}: exit {code}; {out / (phase + '.log')}", flush=True)
    if code and phase != "compatibility":
        sys.exit(code)

    reference = env.get("MOKUME_SPHERE_REFERENCE")
    if phase == "compatibility" and reference:
        rows = []
        with (out / "compatibility.csv").open() as data:
            scenes = [row["scene"] for row in csv.DictReader(data)]
        for scene in scenes:
            row = {"scene": scene}
            for mode in ["before", "after"]:
                for suffix, format in [("rgba16f", "<H"), ("shape32", "<I")]:
                    old = (Path(reference) / f"{scene}-before.{suffix}").read_bytes()
                    new = (out / f"{scene}-{mode}.{suffix}").read_bytes()
                    if len(old) != len(new):
                        raise ValueError(f"{scene}: incompatible dimensions")
                    a = [v[0] for v in struct.iter_unpack(format, old)]
                    b = [v[0] for v in struct.iter_unpack(format, new)]
                    row[mode + "_" + suffix + "_differing_components"] = sum(x != y for x, y in zip(a, b))
                row[mode + "_png_equal"] = ((Path(reference) / f"{scene}-before.png").read_bytes()
                                            == (out / f"{scene}-{mode}.png").read_bytes())
            rows.append(row)
            print("main comparison:", row, flush=True)
        (out / "main-comparison.json").write_text(json.dumps(rows, indent=2))
        if any(any(row[mode + "_rgba16f_differing_components"]
                       or row[mode + "_shape32_differing_components"]
                       or not row[mode + "_png_equal"] for mode in ["before", "after"]) for row in rows):
            sys.exit(2)
    if code:
        sys.exit(code)
