#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-schema-versions.py の検査 (#637)。

固定するのは 3 つで、どれが破れても症状は「緑」である。

- **破壊的な変化を取りこぼさない** — required の追加・キーの削除・型の変更は、
  トップだけでなく `items` の中と `$defs` の中でも捕まる必要がある。取りこぼすと
  #635 (同じ版を名乗る応答が 2 通りになる) がそのまま再発する
- **据え置きが正しい変更では黙る** — 説明の書き換えと値域の拡大で赤くなる検査は、
  すぐに「とりあえず版を上げる」を招く。そうなると版はもう新旧を表さない
- **比較の相手を引けないときは通る** — 材料が無いことは書いた人の落ち度ではない。
  ただし見ていないことは名乗る

実行は make hooks-test (CI もこれを呼ぶ)。git だけを使い、ネットワークには出ない。
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-schema-versions.py"

# 検査したい形だけを持つ、小さな面。実物 (Schemas/observe-report.schema.json) の
# 構造 — 入れ子の required・items の中の required・$defs — を写している
BASE = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "検査用の面",
    "type": "object",
    "required": ["schemaVersion", "id"],
    "additionalProperties": False,
    "properties": {
        "schemaVersion": {"const": 1, "description": "この応答の形式の版。"},
        "id": {"type": "string", "minLength": 1, "description": "要求の識別子。"},
        "note": {"type": "string", "description": "任意の鍵 (required に入らない)。"},
        "kind": {"type": "string", "examples": ["nominal", "fair"]},
        "size": {
            "type": "object",
            "required": ["width"],
            "properties": {"width": {"type": "integer", "minimum": 1}},
        },
        "frames": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["image"],
                "properties": {
                    "image": {"type": "string"},
                    "stats": {"$ref": "#/$defs/stats"},
                },
            },
        },
    },
    "$defs": {
        "stats": {
            "type": "object",
            "required": ["mean"],
            "properties": {"mean": {"type": "number", "minimum": 0, "maximum": 1}},
        }
    },
}

VERSIONLESS = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "検査用の要求 (版を持たない)",
    "type": "object",
    "required": ["id"],
    "properties": {"id": {"type": "string"}},
}


class SchemaVersionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.git("init", "-q", "-b", "main", ".")
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit を打つので
        # 署名鍵が要求され、エージェントが応えられない一瞬で 128 になる
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "user.name", "検査")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / "Schemas").mkdir()
        self.write("probe", BASE)
        self.commit("最初の面")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def write(self, name, document):
        path = self.root / "Schemas" / f"{name}.schema.json"
        path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")

    def edit(self, mutate, name="probe"):
        """作業ツリーの面を書き換える (commit はしない — 手元の変更として見せる)。"""
        document = json.loads(json.dumps(BASE))
        mutate(document)
        self.write(name, document)

    def run_check(self, base="main"):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--base", base],
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        return result.returncode, result.stdout + result.stderr

    # --- 破壊的な変化を取りこぼさない ---

    def test_required_added_without_bump_is_red(self):
        self.edit(lambda d: d["required"].append("note"))
        code, output = self.run_check()
        self.assertEqual(code, 1, output)
        self.assertIn("note", output)
        self.assertIn("required に追加", output)
        # 何をすればよいかが出ていること (赤の読み手は次の一手を探す)
        self.assertIn("schemaVersion.const を 2 へ上げる", output)

    def test_nested_required_added_is_red(self):
        def mutate(document):
            document["properties"]["frames"]["items"]["required"].append("stats")
            document["$defs"]["stats"]["required"].append("max")

        self.edit(mutate)
        code, output = self.run_check()
        self.assertEqual(code, 1, output)
        self.assertIn("/properties/frames/items", output)
        self.assertIn("/$defs/stats", output)

    def test_removed_key_is_red(self):
        self.edit(lambda d: d["properties"].pop("note"))
        code, output = self.run_check()
        self.assertEqual(code, 1, output)
        self.assertIn("キーが消えた", output)
        self.assertIn("note", output)

    def test_renamed_key_is_red(self):
        """改名は「消えた + 増えた」として現れるので、消えた側で捕まる。"""

        def mutate(document):
            document["properties"]["memo"] = document["properties"].pop("note")

        self.edit(mutate)
        code, output = self.run_check()
        self.assertEqual(code, 1, output)
        self.assertIn("note", output)

    def test_changed_type_is_red(self):
        self.edit(lambda d: d["properties"]["id"].update({"type": "integer"}))
        code, output = self.run_check()
        self.assertEqual(code, 1, output)
        self.assertIn("型が変わった", output)
        self.assertIn("string → integer", output)

    def test_bumped_version_is_green(self):
        def mutate(document):
            document["required"].append("note")
            document["properties"]["schemaVersion"]["const"] = 2

        self.edit(mutate)
        code, output = self.run_check()
        self.assertEqual(code, 0, output)
        self.assertIn("版が上がっている (1 → 2)", output)

    # --- 据え置きが正しい変更では黙る ---

    def test_description_and_range_widening_is_silent(self):
        """説明の書き換え・値域と列挙の拡大・任意キーの追加では赤くならない。"""

        def mutate(document):
            document["properties"]["id"]["description"] = "まったく違う説明。"
            document["properties"]["kind"]["examples"].append("blazing")
            document["properties"]["size"]["properties"]["width"]["minimum"] = 0
            document["$defs"]["stats"]["properties"]["mean"]["maximum"] = 2
            document["properties"]["extra"] = {"type": "string", "description": "任意。"}

        self.edit(mutate)
        code, output = self.run_check()
        self.assertEqual(code, 0, output)
        self.assertIn("破壊的な変化なし", output)

    def test_new_object_with_required_is_silent(self):
        """新しく足したオブジェクトの中の required は「増えた」ではない。"""

        def mutate(document):
            document["properties"]["load"] = {
                "type": "object",
                "required": ["thermalState"],
                "properties": {"thermalState": {"type": "string"}},
            }

        self.edit(mutate)
        code, output = self.run_check()
        self.assertEqual(code, 0, output)

    # --- 対象の外にあるもの ---

    def test_schema_without_version_is_out_of_scope(self):
        """要求は版を持たない (ADR-0018 決定 5)。求められるものが無いので黙る。"""
        self.write("probe-request", VERSIONLESS)
        self.commit("要求の面を足す")
        document = json.loads(json.dumps(VERSIONLESS))
        document["required"].append("extra")
        document["properties"]["extra"] = {"type": "string"}
        self.write("probe-request", document)
        code, output = self.run_check()
        self.assertEqual(code, 0, output)
        self.assertIn("schemaVersion を持たない", output)

    def test_new_schema_is_out_of_scope(self):
        """比較の相手が無い面 (新しく足した面) では黙る。"""
        self.write("fresh", BASE)
        code, output = self.run_check()
        self.assertEqual(code, 0, output)
        self.assertIn("には無い (新しい面)", output)

    # --- 比較の相手を引けないとき ---

    def test_unreachable_base_is_silent_and_says_so(self):
        """浅い clone でネットワークも無いとき — 黙って通り、見ていないことを名乗る。

        一時リポジトリには origin が無いので fetch は即失敗する (外へは出ない)。
        """
        self.edit(lambda d: d["required"].append("note"))
        code, output = self.run_check(base="origin/main")
        self.assertEqual(code, 0, output)
        self.assertIn("見ていない", output)

    def test_no_schemas_is_red(self):
        """対象が 0 件で通ると、何も見ていない緑になる。"""
        (self.root / "Schemas" / "probe.schema.json").unlink()
        code, output = self.run_check()
        self.assertEqual(code, 1, output)
        self.assertIn("スキーマが 1 つも見つからない", output)


if __name__ == "__main__":
    unittest.main()
