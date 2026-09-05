#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""ワイヤ形の綴りが、Swift と `Schemas/` で割れていないかを見る (#803)。

プロセスの外へ出る形の正典は `Schemas/*.schema.json` で、Swift は従う側である
([ADR-0018](../../docs/decisions/0018-observation-and-control-surface.md))。
綴りの全集合は Swift 側にも `enum` として在り、**両者はコンパイラにも
`check-jsonschema` にも見えない**。代表例 (`Schemas/examples/`) は正典どおりに
書いてあるので、Swift が別の綴りを出し始めても例のほうは通り続ける。

割れたときの壊れ方は「黙って違う挙動になる」— 置いた値が入らない・送った出来事が
効かない、としか出ない。だから Swift の `enum` と schema の `enum` を突き合わせる。

**新しい的は増えない。** 材料が両方ともリポジトリの中にあり比べるだけなので、
`make hooks-test` が既に拾うここに置く
([ADR-0008](../../docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 5 段 1)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCES = REPO / "Sources" / "MokumeCore"
SCHEMAS = REPO / "Schemas"

# `case float` も `case float(Double)` も拾う (綴りは開き括弧の手前まで)
CASE = re.compile(r"^\s*case (\w+)", re.MULTILINE)


def cases(path: Path) -> list[str]:
    """Swift の `enum` 1 つぶんのケースの綴り。

    どのファイルも `enum` を 1 つだけ持つ (持たせる) 前提で、本文の `case` を拾う。
    """
    text = path.read_text(encoding="utf-8")
    found = CASE.findall(text)
    assert found, f"{path} に case が 1 つも無い"
    return found


def schema_at(name: str, pointer: list[str]) -> list[str]:
    """schema の中の 1 つの `enum` / `examples`。

    位置を JSON Pointer で名指しするのは、**探し当てた結果ではなく指定した場所を
    見ている**ことを、この検査自身が言えるようにするため — 構造が変わったら
    KeyError で落ちる (静かに 0 件と比べない)。
    """
    node = json.loads((SCHEMAS / f"{name}.schema.json").read_text(encoding="utf-8"))
    for step in pointer:
        node = node[int(step)] if isinstance(node, list) else node[step]
    return node


class WireVocabularyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.param_types = cases(SOURCES / "Parameters" / "ParamTypeName.swift")
        self.exposed = cases(SOURCES / "Observation" / "ExposedValue.swift")
        self.event_types = cases(SOURCES / "Input" / "InputEventType.swift")

    def test_つまみの型名が両方の面と一致する(self):
        for name, pointer in (
            ("params-report", ["properties", "params", "items", "properties", "type", "enum"]),
            ("params-request", ["properties", "values", "items", "properties", "type", "enum"]),
        ):
            with self.subTest(schema=name):
                self.assertEqual(
                    sorted(self.param_types),
                    sorted(schema_at(name, pointer)),
                    f"ParamTypeName の綴りと Schemas/{name}.schema.json の enum が割れている",
                )

    def test_観測が出す型名が観測の面と一致する(self):
        self.assertEqual(
            sorted(self.exposed),
            sorted(
                schema_at(
                    "observe-report",
                    ["$defs", "values", "additionalProperties", "properties", "type", "enum"],
                )
            ),
            "ExposedValue の綴りと Schemas/observe-report.schema.json の enum が割れている",
        )

    def test_観測が出す型名はつまみの型名の部分集合である(self):
        # 名乗り方を分け合っている以上、観測だけが知る綴りは在ってはならない
        # (ADR-0030 決定 4)。観測に色や組が要る日は、両方へ足す
        extra = sorted(set(self.exposed) - set(self.param_types))
        self.assertEqual(
            extra, [], f"ExposedValue だけが持つ綴り: {', '.join(extra)} (ParamTypeName へも足す)"
        )

    def test_出来事の種別が入力の面と一致する(self):
        # 入力の面は `enum` で縛らない — 知らない種別は、その 1 件だけが捨てられる
        # 設計だからである (ADR-0018 決定 3)。読み手が知っている綴りの全集合は
        # `examples` が名乗っており、そこと突き合わせる
        self.assertEqual(
            sorted(self.event_types),
            sorted(
                schema_at(
                    "input-request",
                    ["properties", "events", "items", "properties", "type", "examples"],
                )
            ),
            "InputEventType の綴りと Schemas/input-request.schema.json の examples が割れている",
        )

    def test_必須の値を課す条件分岐が知らない種別を指していない(self):
        # 種別ごとに必須の鍵を課す allOf も同じ綴りを持つ。読み手の知らない綴りを
        # 指していると、その条件は永久に発火しない
        node = schema_at("input-request", ["properties", "events", "items", "allOf"])
        for index, branch in enumerate(node):
            with self.subTest(branch=index):
                unknown = sorted(
                    set(branch["if"]["properties"]["type"]["enum"]) - set(self.event_types)
                )
                self.assertEqual(unknown, [], f"読み手の知らない種別を指している: {', '.join(unknown)}")


if __name__ == "__main__":
    unittest.main()
