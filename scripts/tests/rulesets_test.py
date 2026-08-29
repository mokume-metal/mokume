#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""ルールセットの定義ファイルと照合・適用の検査 (#98)。

固定したいのは三つ:

  1. 定義ファイルの形の検査が、GET の応答をそのまま置いた事故 (id 等の混入) と
     bypass_actors の欠落を落とす — ADR-0003 決定 1 は書かれていて初めて検査できる
  2. 実設定に bypass_actors が無い (= その認証では読めない) とき、黙って一致と
     言わない — 既定は赤、--without-bypass-actors なら緑にするが**何を見ていないか
     を名乗る**。一番危ない項目を見ていない緑を、黙って作らないため (ADR-0006 / #99)
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
#
# main 側 (#311 の鮮度判定が引く 2 本) は環境変数で差し替える。どちらも未設定なら
# 引けなかったものとして落とす — 「判定できなかった」経路もこれで再現できる。
#   gh api repos/X/contents/.github/rulesets?ref=main → FAKE_MAIN_DEFS_DIR の name<TAB>blob SHA
#   gh api repos/X/commits?path=...&sha=main          → FAKE_MAIN_RULESET_COMMIT
FAKE_GH = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys

args = sys.argv[1:]
joined = " ".join(args)
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(joined + "\n")

live = pathlib.Path(os.environ["FAKE_LIVE_DIR"])
files = sorted(live.glob("*.json"))

endpoint = next((a for a in args if a.startswith("repos/")), "")

if "/contents/" in endpoint:
    defs = os.environ.get("FAKE_MAIN_DEFS_DIR")
    if not defs:
        sys.exit(1)
    for f in sorted(pathlib.Path(defs).glob("*.json")):
        blob = f.read_bytes()
        # git の blob SHA。contents API の .sha はこれと同じものを返す
        sha = hashlib.sha1(b"blob %d\0" % len(blob) + blob).hexdigest()
        print(f"{f.name}\t{sha}")
    sys.exit(0)

if "/commits?" in endpoint:
    sha = os.environ.get("FAKE_MAIN_RULESET_COMMIT")
    if not sha:
        sys.exit(1)
    print(sha)
    sys.exit(0)

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

    def diff(self, *flags):
        return run(["python3", str(LIB), "diff", str(DEFS), str(self.live), *flags])

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

    def test_読めないときに許すフラグは何を見ていないかを名乗る(self):
        # CI の GITHUB_TOKEN では bypass_actors が返らない (#99 で実測)。緑にはするが、
        # 「全部一致」と読まれないよう出力で名乗らせる
        self.mutate("main-protection", lambda b: b.pop("bypass_actors"))
        r = self.diff("--without-bypass-actors")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("bypass_actors は検査していない", r.stdout)

    def test_読めないときに許しても他の差分は拾う(self):
        # 見ない項目が 1 つ増えるだけで、検査そのものが緩むわけではない
        def shift(body):
            body.pop("bypass_actors")
            body["enforcement"] = "evaluate"

        self.mutate("main-protection", shift)
        r = self.diff("--without-bypass-actors")
        self.assertEqual(r.returncode, 1)
        self.assertIn("定義とずれている", r.stderr)

    def test_フラグを付けても読めるなら_bypass_actors_を比較する(self):
        # フラグは「読めなかったときに許す」であって「常に無視する」ではない。
        # 手元の認証で誤ってフラグを付けても、bypass の追加は取りこぼさない
        self.mutate(
            "main-protection",
            lambda b: b.__setitem__("bypass_actors", [{"actor_id": 1, "actor_type": "Integration", "bypass_mode": "always"}]),
        )
        r = self.diff("--without-bypass-actors")
        self.assertEqual(r.returncode, 1)
        self.assertIn("定義とずれている", r.stderr)

    def test_知らないフラグは使い方の誤りとして落ちる(self):
        r = self.diff("--ignore-everything")
        self.assertEqual(r.returncode, 2)
        self.assertIn("不明なフラグ", r.stderr)

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
                # 鮮度判定 (#311) の材料。ここでは本物のリポジトリで走るので、
                # main の定義 = 手元の定義とみなして静かに通す
                "FAKE_MAIN_DEFS_DIR": str(DEFS),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_shape_は_gh_を呼ばない(self):
        r = run(["/bin/bash", str(CHECK), "--shape"], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), "")

    def test_照合は一致で通る(self):
        r = run(["/bin/bash", str(CHECK)], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_照合は実設定がずれれば落ちる(self):
        f = next(f for f in self.live.glob("*.json") if "signed" in f.read_text())
        body = json.loads(f.read_text())
        body["enforcement"] = "disabled"
        f.write_text(json.dumps(body))
        r = run(["/bin/bash", str(CHECK)], env=self.env)
        self.assertEqual(r.returncode, 1)

    def test_apply_は既定では書き換えない(self):
        f = next(f for f in self.live.glob("*.json") if "signed" in f.read_text())
        body = json.loads(f.read_text())
        body["enforcement"] = "disabled"
        f.write_text(json.dumps(body))

        r = run(["/bin/bash", str(APPLY)], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--apply", r.stdout)
        self.assertNotIn("PUT", self.calls())
        self.assertEqual(json.loads(f.read_text())["enforcement"], "disabled")

    def test_apply_フラグ付きなら書き換えて照合まで通す(self):
        f = next(f for f in self.live.glob("*.json") if "signed" in f.read_text())
        body = json.loads(f.read_text())
        body["enforcement"] = "disabled"
        f.write_text(json.dumps(body))

        r = run(["/bin/bash", str(APPLY), "--apply"], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PUT", self.calls())
        self.assertEqual(json.loads(f.read_text())["enforcement"], "active")

    def test_apply_は差分が無ければ何もしない(self):
        r = run(["/bin/bash", str(APPLY), "--apply"], env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("PUT", self.calls())


class FreshnessTest(unittest.TestCase):
    """照合の結果が「どの版の定義について」のものかを名乗るか (#311)。

    照合するのは手元にチェックアウトされている定義なので、古い版のツリーから打つと
    **古い定義と古い実設定が一致して緑になる**。ここで固定したいのは三つ:

      1. わざと古いツリーで打つと、緑のまま「古い」と名乗る (Issue の完了条件 3)
      2. 名乗りは照合の結果より先に出る (後から読ませると緑が先に目に入る)
      3. 定義を編集している最中の作業ブランチを「古い」と言わない

    そのために**本物の git リポジトリを一時的に作る** — 古いツリーは git の状態でしか
    表現できず、偽物で置き換えると再現したい事象そのものが消える。main 側は偽 gh が
    返すので、ネットワークも認証も要らない。
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        # 定義の 2 世代。merge queue の並列ビルド上限だけが違う
        self.old_defs = self.make_defs(root / "old-defs", 4)
        self.new_defs = self.make_defs(root / "new-defs", 6)

        self.repo = root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        self.defs = self.repo / ".github" / "rulesets"
        self.defs.mkdir(parents=True)
        for src in (CHECK, LIB):
            shutil.copy(src, self.repo / "scripts" / src.name)

        self.git("init", "-q")
        self.put_defs(self.old_defs)
        self.old = self.commit("古い定義")
        self.put_defs(self.new_defs)
        self.new = self.commit("新しい定義 (main)")

        self.live = root / "live"
        self.live.mkdir()
        self.set_live(self.new_defs)

        bin_dir = root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

        self.env = dict(os.environ)
        self.env.update(
            {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "FAKE_GH_LOG": str(root / "gh.log"),
                "FAKE_LIVE_DIR": str(self.live),
                "FAKE_MAIN_DEFS_DIR": str(self.new_defs),
                "FAKE_MAIN_RULESET_COMMIT": self.new,
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )

    @staticmethod
    def make_defs(dst, entries):
        """本物の定義を写し、1 項目だけ動かした世代を作る。"""
        dst.mkdir()
        for f in DEFS.glob("*.json"):
            body = json.loads(f.read_text())
            for rule in body.get("rules", []):
                if rule["type"] == "merge_queue":
                    rule["parameters"]["max_entries_to_build"] = entries
            (dst / f.name).write_text(
                json.dumps(body, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
            )
        return dst

    def git(self, *args):
        env = dict(os.environ)
        env.update(
            {
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@example.invalid",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@example.invalid",
            }
        )
        r = subprocess.run(
            ["git", "-C", str(self.repo), "-c", "commit.gpgsign=false", *args],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        return r.stdout.strip()

    def put_defs(self, src):
        for f in self.defs.glob("*.json"):
            f.unlink()
        for f in src.glob("*.json"):
            shutil.copy(f, self.defs / f.name)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def set_live(self, src):
        """実設定を作る。ここを定義と同じにすると照合そのものは緑になる。"""
        for f in self.live.glob("*.json"):
            f.unlink()
        for i, f in enumerate(sorted(src.glob("*.json")), start=1):
            (self.live / f"{i}.json").write_text(f.read_text())

    def check(self, **env):
        """stdout と stderr を 1 本にまとめて回す (名乗りと結果の前後関係を見るため)。"""
        e = dict(self.env)
        for k, v in env.items():
            e.pop(k) if v is None else e.update({k: v})
        r = subprocess.run(
            ["/bin/bash", str(self.repo / "scripts" / CHECK.name)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=e,
            cwd=self.repo,
            check=False,
        )
        return r.returncode, r.stdout

    def test_古いツリーで打つと緑のまま古いと名乗る(self):
        # #311 の事象そのもの。古い定義と古い実設定は一致するので照合は緑になる
        self.git("checkout", "-q", self.old)
        self.set_live(self.old_defs)
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("ok: main-protection は定義と一致", out)
        self.assertIn("手元のツリーは古い", out)
        self.assertIn("main-protection.json", out)

    def test_名乗りは照合の結果より先に出る(self):
        self.git("checkout", "-q", self.old)
        self.set_live(self.old_defs)
        _, out = self.check()
        # 先に出るべき相手は照合の結果 (形の検査の ok: はそれ以前に出る)
        self.assertLess(
            out.index("手元のツリーは古い"), out.index("ok: main-protection は定義と一致"), out
        )

    def test_main_と同じツリーでは何も言わない(self):
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertNotIn("注意", out)

    def test_定義を編集中の作業ブランチは古いと言わない(self):
        # main の最新の定義変更は HEAD に入っている。違うのは手元の編集のぶんだけ
        edited = self.make_defs(Path(self.tmp.name) / "edited", 9)
        self.put_defs(edited)
        self.set_live(edited)
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("編集中とみられる", out)
        self.assertNotIn("古い", out)

    def test_main_を引けなければ確かめていないと名乗る(self):
        code, out = self.check(FAKE_MAIN_DEFS_DIR=None)
        self.assertEqual(code, 0, out)
        self.assertIn("確かめていない", out)

    def test_向きが分からなければ古いとは言わない(self):
        # 中身は違うと分かっても、どちら向きかを判定する材料が無いときに断定しない
        self.git("checkout", "-q", self.old)
        self.set_live(self.old_defs)
        code, out = self.check(FAKE_MAIN_RULESET_COMMIT=None)
        self.assertEqual(code, 0, out)
        self.assertIn("判定していない", out)
        self.assertNotIn("手元のツリーは古い", out)


if __name__ == "__main__":
    unittest.main()
