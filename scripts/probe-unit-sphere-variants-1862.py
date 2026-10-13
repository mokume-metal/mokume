#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""#1862 試作専用。ビルド済み資源だけを一時交換し、互換性検査の後に必ず復元する。

先にreleaseをビルドする。ビルドや別のGPU検査と同時に使わない。
python3 scripts/probe-unit-sphere-variants-1862.py plain
選択: plain / volatile / noinline / contract_off / explicit_world / fma0..11 / mutant
fma0 は保存した専用シェーダの方式。fma1..5 は平行移動から始める順列、
fma6..11 は平行移動を最後に足す順列。初回実測では fma6,8,10,7,9,11,0 の順で試した。
MOKUME_SPHERE_OUTPUT と MOKUME_SPHERE_SCENES は主runnerへ渡す。
"""
from pathlib import Path
import hashlib
import itertools
import json
import os
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
mode = sys.argv[1]
original = (root / "Sources/MokumeCore/Drawing/Shaders/UnitSphere.metal").read_text()
source = re.sub(r"    float4 world = fma[\s\S]*?;", "    float4 world = placement.matrix * float4(vertex_in.position, 1.0);", original, count=1)
assert source != original
if mode == "volatile":
    source = source.replace("float3 scaled =", "volatile float3 scaled =")
elif mode == "noinline":
    source = source.replace("vertex ShapeFragmentIn unitSphereVertexMain(", "__attribute__((noinline)) float3 sphereScale(float3 n, float r) { return n * r; }\nvertex ShapeFragmentIn unitSphereVertexMain(")
    source = source.replace("vertex_in.normal.xyz * placement.normal0.w", "sphereScale(vertex_in.normal.xyz, placement.normal0.w)")
elif mode == "contract_off":
    source = source.replace("constant SolidInstance *instances [[buffer(10)]])\n{", "constant SolidInstance *instances [[buffer(10)]])\n{\n    #pragma clang fp contract(off)")
elif mode == "explicit_world":
    source = source.replace("    float4 world = placement.matrix * float4(vertex_in.position, 1.0);", "    float4 world;\n    {\n        #pragma clang fp reassociate(off)\n        float3 p = vertex_in.position;\n        world = ((placement.matrix[0] * p.x + placement.matrix[1] * p.y) + placement.matrix[2] * p.z) + placement.matrix[3];\n    }")
elif mode.startswith("fma"):
    k = int(mode[3:])
    assert 0 <= k < 12
    order = list(itertools.permutations(range(3)))[k % 6]
    terms = ["vertex_in.position.x", "vertex_in.position.y", "vertex_in.position.z"]
    if k < 6:
        expr = "placement.matrix[3]"
        for i in order:
            expr = f"fma(placement.matrix[{i}], {terms[i]}, {expr})"
    else:
        i, j, h = order
        expr = f"(fma(placement.matrix[{h}], {terms[h]}, fma(placement.matrix[{j}], {terms[j]}, placement.matrix[{i}] * {terms[i]})) + placement.matrix[3])"
    source = source.replace("placement.matrix * float4(vertex_in.position, 1.0)", expr)
elif mode == "mutant":
    source = original.replace("vertex_in.shapePosition = scaled;", "vertex_in.shapePosition = scaled;\n    vertex_in.shapePosition.x = as_type<float>(as_type<uint>(scaled.x) ^ 1u);")
elif mode != "plain":
    raise ValueError(mode)
paths = list((root / ".build/out/Products/Release").rglob("mokume_MokumeCore.bundle/Contents/Resources/UnitSphere.metal"))
assert paths, "先にreleaseでビルドする"
backups = {p: p.read_bytes() for p in paths}
assert all(b == original.encode() for b in backups.values()), "生成済み資源が原本と異なるので実行しない"
out = Path(os.environ.get("MOKUME_SPHERE_OUTPUT", "/private/tmp/mokume-sphere-1862/results"))
out.mkdir(parents=True, exist_ok=True)
(out / "variant.metal").write_text(source)
(out / "variant.json").write_text(json.dumps({"mode": mode, "sha256": hashlib.sha256(source.encode()).hexdigest()}))
try:
    for p in paths:
        p.write_text(source)
    result = subprocess.run([sys.executable, str(root / "scripts/probe-unit-sphere-1862.py"), "compatibility"], cwd=root, timeout=650)
finally:
    for p, data in backups.items():
        p.write_bytes(data)
sys.exit(result.returncode)
