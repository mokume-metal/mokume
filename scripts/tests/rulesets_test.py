#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""ルールセットの定義ファイルと照合・適用の検査 (#98)。

固定したいのは三つ:

  1. 定義ファイルの形の検査が、GET の応答をそのまま置いた事故 (id 等の混入) と
     bypass_actors の欠落を落とす — ADR-0003 決定 1 は書かれていて初めて検査できる
  2. 実設定に bypass_actors が無い (= 認証不足で読めていない) とき、黙って一致と
     言わずに赤にする — 一番危ない項目を見ていない緑を作らないため (ADR-0006)
  3. apply が既定では GitHub を書き換えず、--apply を付けたときだけ書き換える

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "rulesets_lib.py"
CHECK = REPO / "scripts" / "check-rulesets.sh"
APPLY = REPO / "scripts" / "apply-rulesets.sh"
DEFS = REPO / ".github" / "rulesets"

# 偽 gh。実設定は FAKE_LIVE_DIR の <id>.json が正本という約束にする。
#   gh api repos/X/rulesets --jq .[].id              → id の一覧
#   gh api repos/X/rulesets --jq '.[] | "(name)(id)"' → name<TAB>id
#   gh api repos/X/rulesets/<id>                     → その JSON
#   gh api -X PUT|POST ... --input <f>               → FAKE_LIVE_DIR を書き換える
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys

args = sys.argv[1:]
joined = " ".join(args)
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(joined + "\n")

live = pathlib.Path(os.environ["FAKE_LIVE_DIR"])
files = sorted(live.glob("*.json"))

endpoint = next((a for a in args if a.startswith("repos/")), "")

if "PUT" in args or "POST" in args:
    src = pathlib.Path(args[args.index("--input") + 1])
    # PUT は repos/<owner>/<repo>/rulesets/<id>、POST は末尾が rulesets (新規作成)
    target = endpoint.rsplit("/", 1)[-1] if "/rulesets/" in endpoint else "new"
    (live / f"{target}.json").write_text(src.read_text())
    sys.exit(0)

if ".[].id" in joined:
    print("\n".join(f.stem for f in files))
    sys.exit(0)

if "(.name)" in joined:
    for f in files:
        print(f"{json.loads(f.read_text())['name']}\t{f.stem}")
    sys.exit(0)

for f in files:
    if endpoint.endswith("rulesets/" + f.stem):
        print(f.read_text())
        sys.exit(0)

sys.exit(1)
'''


def run(cmd, env=None, cwd=None):
    return subprocess.run(
        cmd, capture_output=True, text=True, env=env, cwd=cwd or REPO, check=False
    )


class ShapeTest(unittest.TestCase):
    """定義ファイルの形の検査 (token 不要)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        for f in DEFS.glob("*.json"):
            shutil.copy(f, self.dir / f.name)

    def shape(self):
        return run(["python3", str(LIB), "shape", str(self.dir)])

    def rewrite(self, name, mutate):
        path = self.dir / name
        body = json.loads(path.read_text())
        mutate(body)
        path.write_text(json.dumps(body, indent=2, ensure_ascii=False, sort_keys=True))

    def test_リポジトリの定義はそのまま通る(self):
        r = self.shape()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_GET_の応答をそのまま置くと落ちる(self):
        self.rewrite("main-protection.json", lambda b: b.update({"id": 21453049}))
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("PUT へ渡せない鍵", r.stderr)

    def test_bypass_actors_の欠落は落ちる(self):
        self.rewrite("main-protection.json", lambda b: b.pop("bypass_actors"))
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("bypass_actors", r.stderr)

    def test_必須の鍵の欠落は落ちる(self):
        self.rewrite("signed-commits.json", lambda b: b.pop("rules"))
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("必須の鍵が無い", r.stderr)

    def test_enforcement_の値が不正なら落ちる(self):
        self.rewrite("signed-commits.json", lambda b: b.update({"enforcement": "on"}))
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("enforcement", r.stderr)

    def test_ファイル名と_name_のずれは落ちる(self):
        (self.dir / "signed-commits.json").rename(self.dir / "signed.json")
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("ファイル名が name", r.stderr)

    def test_JSON_として壊れていれば落ちる(self):
        (self.dir / "release-tags.json").write_text("{")
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("JSON として不正", r.stderr)

    def test_定義が_1_本も無ければ落ちる(self):
        for f in self.dir.glob("*.json"):
            f.unlink()
        r = self.shape()
        self.assertEqual(r.returncode, 1)
        self.assertIn("1 つも無い", r.stderr)


class DiffTest(unittest.TestCase):
    """定義と実設定の照合。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.live = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        # 実設定は定義と同じ中身から始め、id をファイル名にする (GET の保存形)
        for i, f in enumerate(sorted(DEFS.glob("*.json")), start=1):
            (self.live / f"{i}.json").write_text(f.read_text())

    def diff(self):
        return run(["python3", str(LIB), "diff", str(DEFS), str(self.live)])

    def live_file(self, name):
        for f in self.live.glob("*.json"):
            if json.loads(f.read_text())["name"] == name:
                return f
        raise AssertionError(f"{name} が実設定に無い")

    def mutate(self, name, fn):
        f = self.live_file(name)
        body = json.loads(f.read_text())
        fn(body)
        f.write_text(json.dumps(body))

    def test_一致していれば通る(self):
        r = self.diff()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_1_項目ずれれば落ちる(self):
        def shift(body):
            for rule in body["rules"]:
                if rule["type"] == "merge_queue":
                    rule["parameters"]["max_entries_to_build"] = 6

        self.mutate("main-protection", shift)
        r = self.diff()
        self.assertEqual(r.returncode, 1)
        self.assertIn("定義とずれている", r.stderr)

    def test_bypass_actors_に誰かが入れば落ちる(self):
        # ADR-0003 決定 1 が守っている一点。ここが赤くならない検査は意味を持たない
        self.mutate(
            "main-protection",
            lambda b: b.__setitem__("bypass_actors", [{"actor_id": 1, "actor_type": "Integration", "bypass_mode": "always"}]),
        )
        r = self.diff()
        self.assertEqual(r.returncode, 1)
        self.assertIn("定義とずれている", r.stderr)

    def test_実設定に_bypass_actors_が無ければ認証不足として落ちる(self):
        # 匿名で読むと bypass_actors は応答に現れない。部分一致で緑にしない
        self.mutate("main-protection", lambda b: b.pop("bypass_actors"))
        r = self.diff()
        self.assertEqual(r.returncode, 1)
        self.assertIn("認証が足りず", r.stderr)

    def test_rules_の順序違いは通る(self):
        self.mutate("main-protection", lambda b: b["rules"].reverse())
        r = self.diff()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_定義にあるルールセットが未適用なら落ちる(self):
        self.live_file("release-tags").unlink()
        r = self.diff()
        self.assertEqual(r.returncode, 1)
        self.assertIn("実設定に存在しない", r.stderr)

    def test_定義に無いルールセットが実在すれば落ちる(self):
        (self.live / "99.json").write_text(
            json.dumps(
                {
                    "name": "手で足された保護",
                    "target": "branch",
                    "enforcement": "active",
                    "conditions": {"ref_name": {"include": ["~ALL"], "exclude": []}},
                    "rules": [{"type": "deletion"}],
                    "bypass_actors": [],
                }
            )
        )
        r = self.diff()
        self.assertEqual(r.returncode, 1)
        self.assertIn("定義に無い", r.stderr)


class ScriptTest(unittest.TestCase):
    """入口の 2 本 (gh は偽物に差し替える)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.live = root / "live"
        self.live.mkdir()
        for i, f in enumerate(sorted(DEFS.glob("*.json")), start=1):
            (self.live / f"{i}.json").write_text(f.read_text())

        bin_dir = root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

        self.log = root / "gh.log"
        self.env = dict(os.environ)
        self.env.update(
            {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_LIVE_DIR": str(self.live),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_shape_は_gh_を呼ばない(self):
        r = run(["bash", str(CHECK), "--shape"], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), "")

    def test_照合は一致で通る(self):
        r = run(["bash", str(CHECK)], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_照合は実設定がずれれば落ちる(self):
        f = next(f for f in self.live.glob("*.json") if "signed" in f.read_text())
        body = json.loads(f.read_text())
        body["enforcement"] = "disabled"
        f.write_text(json.dumps(body))
        r = run(["bash", str(CHECK)], env=self.env)
        self.assertEqual(r.returncode, 1)

    def test_apply_は既定では書き換えない(self):
        f = next(f for f in self.live.glob("*.json") if "signed" in f.read_text())
        body = json.loads(f.read_text())
        body["enforcement"] = "disabled"
        f.write_text(json.dumps(body))

        r = run(["bash", str(APPLY)], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--apply", r.stdout)
        self.assertNotIn("PUT", self.calls())
        self.assertEqual(json.loads(f.read_text())["enforcement"], "disabled")

    def test_apply_フラグ付きなら書き換えて照合まで通す(self):
        f = next(f for f in self.live.glob("*.json") if "signed" in f.read_text())
        body = json.loads(f.read_text())
        body["enforcement"] = "disabled"
        f.write_text(json.dumps(body))

        r = run(["bash", str(APPLY), "--apply"], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PUT", self.calls())
        self.assertEqual(json.loads(f.read_text())["enforcement"], "active")

    def test_apply_は差分が無ければ何もしない(self):
        r = run(["bash", str(APPLY), "--apply"], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("PUT", self.calls())


if __name__ == "__main__":
    unittest.main()
