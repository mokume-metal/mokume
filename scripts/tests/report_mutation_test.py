#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""変異の定期の結果を追跡用の Issue に置く検査 (#3221)。

`scripts/report-mutation.py` (書く側) と `scripts/mutation_state.py` (読む側) を、Issue を 1 本持つ偽 gh
で通す。固定するのは:

  1. 追跡用の Issue が無ければ固定タイトルで立て、`verify: triaged` は付けない (着手できる仕事ではない)
  2. 在れば本文の機械の区画だけを書き換え、区画の外 (人が書いた文) は触らない。点数の更新ではコメントしない
  3. コメントするのは新しい生き残りだけ — 前の回に無い束の生き残りと、範囲の生き残り。同じ生き残りが
     続く間は黙る。立てた回は本文に全部あるのでコメントしない
  4. 記録が無い・読めない・形が違う回は `unreadable` と名乗り、「生き残り 0」と出さない。点数の表は前回の
     まま、範囲の起点 (range_head) は進めない。コメントは読めなくなった回の 1 度だけ、連続は区画の回数だけ
  5. 範囲を回すつもりが無かった最初の回は、束が読めれば起点を HEAD に置く
  6. `previous` は、Issue が無い・区画が無い (何も出さず 0) と、gh が失敗した (1) を分ける
  7. 区画の外へ漏らさない書き換え (begin だけの壊れた区画は人の文を巻き込まず、末尾に足す)

偽 gh は Issue の一覧・本文・型・コメントを JSON のファイルに持ち、呼び出しの列を残す。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import mutation_state as state  # noqa: E402

REPORT = REPO / "scripts" / "report-mutation.py"
HEAD_A = "a" * 40
HEAD_B = "b" * 40
HEAD_C = "c" * 40

FAKE_GH = r"""#!/usr/bin/env python3
import json, os, sys
store_path = os.environ["FAKE_STORE"]
store = json.load(open(store_path))
args = sys.argv[1:]
open(os.environ["FAKE_LOG"], "a").write(" ".join(args) + "\n")

def flag(name):
    return args[args.index(name) + 1] if name in args else None

def save():
    json.dump(store, open(store_path, "w"))

if os.environ.get("FAKE_GH_FAIL") and args[:2] == ["issue", "list"]:
    sys.exit(1)
if args[:2] == ["issue", "list"]:
    print(json.dumps([{"number": i["number"], "title": i["title"]} for i in store["issues"] if i["open"]]))
elif args[:2] == ["issue", "view"]:
    issue = next(i for i in store["issues"] if i["number"] == int(args[2]))
    if "issueType" in args:
        # triage.sh は --jq '.issueType.name // empty' で読む
        print(issue.get("type") or "")
    else:
        print(json.dumps({"body": issue["body"]}))
elif args[:2] == ["issue", "create"]:
    number = len(store["issues"]) + 100
    store["issues"].append({"number": number, "title": flag("--title"), "body": open(flag("--body-file")).read(),
                            "open": True, "labels": [], "type": None, "created_with": args})
    save()
    print(f"https://github.com/o/r/issues/{number}")
elif args[:2] == ["issue", "edit"]:
    issue = next(i for i in store["issues"] if i["number"] == int(args[2]))
    if "--body-file" in args:
        issue["body"] = open(flag("--body-file")).read()
    if "--type" in args:
        issue["type"] = flag("--type")
    save()
elif args[:2] == ["issue", "comment"]:
    store["comments"].append({"number": int(args[2]), "body": open(flag("--body-file")).read()})
    save()
else:
    sys.exit(1)
"""


def result(head, killed=0, survived=0, invalid=0, mutants=None, bundle="Tests/mutation-bundle.json", since=None):
    """mutate.py が書く結果の最小の形。mutants を省けば件数に合わせて作る。"""
    if mutants is None:
        mutants = ([{"id": f"k{i}", "file": "Sources/A.swift", "line": i, "outcome": "killed", "killers": ["X.t"]}
                    for i in range(killed)]
                   + [{"id": f"s{i}", "file": "Sources/B.swift", "line": i, "outcome": "survived",
                       "operator": ">= -> >", "killers": []} for i in range(survived)]
                   + [{"id": f"i{i}", "file": "Sources/C.swift", "line": 1, "outcome": "invalid",
                       "reason": "anchor: 原文が 2 回当たる", "killers": []} for i in range(invalid)])
    counts = {name: 0 for name in ("killed", "survived", "timeout", "invalid", "unevaluated", "unrun")}
    for m in mutants:
        counts[m["outcome"]] += 1
    scored = counts["killed"] + counts["survived"]
    return {"version": 1, "head": head, "since": since, "bundle": None if since else bundle,
            "catalog": {"path": "Tests/probe-catalog.tsv", "state": "present", "rows": 1},
            "seconds": 12.0, "budget": 100, "timeout": 10, "counts": counts,
            "score": round(counts["killed"] / scored, 4) if scored else None,
            "attribution": {"density": {"killed": killed, "sole": 1}} if killed else {}, "mutants": mutants}


class Env:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.bin = bin_dir
        self.store = self.dir / "store.json"
        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.write_store({"issues": [], "comments": []})
        self.runs = 0

    def write_store(self, data):
        self.store.write_text(json.dumps(data))

    def read_store(self):
        return json.loads(self.store.read_text())

    def env(self, **extra):
        env = dict(os.environ)
        env.update({"PATH": f"{self.bin}:{env['PATH']}", "FAKE_STORE": str(self.store), "FAKE_LOG": str(self.log),
                    "RUNNER_TEMP": str(self.dir), "MUTATION_REPORT_NOW": "2026-10-31 19:40"})
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "FAKE_GH_FAIL"):
            env.pop(key, None)
        env.update(extra)
        return env

    def put(self, name, data):
        path = self.dir / name
        path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
        return str(path)

    def report(self, bundle, ranged=None, since="", result_name="success", **extra):
        """bundle / ranged は結果の dict・文字列 (壊れた記録)・None (ファイルが無い)。"""
        self.runs += 1
        run_dir = self.dir / f"run{self.runs}"
        run_dir.mkdir()
        paths = []
        for name, data in (("bundle.json", bundle), ("range.json", ranged)):
            path = run_dir / name
            if data is not None:
                path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
            paths.append(str(path))
        return subprocess.run(
            [sys.executable, str(REPORT), "--result", result_name, "--bundle", paths[0], "--range", paths[1],
             "--range-since", since],
            capture_output=True, text=True, env=self.env(GITHUB_RUN_ID=str(self.runs),
                                                         GITHUB_REPOSITORY="o/r", **extra), cwd=REPO)

    def issue(self):
        issues = self.read_store()["issues"]
        self.assertEqual(len(issues), 1, "追跡用の Issue は 1 本")
        return issues[0]

    def comments(self):
        return self.read_store()["comments"]

    def calls(self, verb):
        return [ln for ln in self.log.read_text().splitlines() if ln.startswith(verb)]


class CreateTest(Env, unittest.TestCase):
    def test_issue_が無ければ固定タイトルで立て_型を付け_着手できる印は付けない(self):
        r = self.report(result(HEAD_A, killed=3, survived=1))
        self.assertEqual(r.returncode, 0, r.stderr)
        issue = self.issue()
        self.assertEqual(issue["title"], state.TITLE)
        self.assertEqual(issue["type"], "Task")  # chore( → Task (triage.sh)
        self.assertNotIn("--label", issue["created_with"])
        self.assertIn(state.BEGIN, issue["body"])
        self.assertIn("評価 4・殺した 3・生き残り 1", issue["body"])
        self.assertEqual(self.comments(), [], "立てた回は本文に全部あるのでコメントしない")
        meta = state.read_meta(issue["body"])
        # 範囲を回すつもりが無かった最初の回は、束が読めれば起点を HEAD に置く
        self.assertEqual(meta["range_head"], HEAD_A)
        self.assertEqual(meta["survivors"], ["s0"])
        self.assertEqual(meta["unreadable"], 0)

    def test_最初の回に読めなくても_unreadable_と名乗って立てる(self):
        r = self.report(None)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("unreadable", body)
        self.assertIn("記録が無い", body)
        self.assertNotIn("生き残り 0", body)
        meta = state.read_meta(body)
        self.assertIsNone(meta["range_head"], "読めない回は起点を置かない")
        self.assertEqual(meta["unreadable"], 1)
        self.assertEqual(meta["history"], [])


class UpdateTest(Env, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.report(result(HEAD_A, killed=3, survived=1))
        issue = self.issue()
        issue["body"] = issue["body"].replace("定期の job", "人が足した一文 HUMAN 定期の job", 1)
        self.write_store({"issues": [issue], "comments": []})

    def test_点数の更新は区画だけを書き換え_コメントしない(self):
        r = self.report(result(HEAD_B, killed=4, survived=1), ranged=result(HEAD_B, killed=2, since=HEAD_A),
                        since=HEAD_A)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("人が足した一文 HUMAN", body, "区画の外は触らない")
        self.assertIn("評価 5・殺した 4・生き残り 1", body)
        self.assertIn("評価 2・殺した 2", body, "範囲の表")
        self.assertEqual(self.comments(), [], "同じ生き残り (s0) が続く間は黙る")
        meta = state.read_meta(body)
        self.assertEqual(meta["range_head"], HEAD_B)
        self.assertEqual([e["head"] for e in meta["history"]], [HEAD_A[:12], HEAD_B[:12]])
        # 本文を書き換える edit は 1 回だけ (もう 1 回は立てたときの triage.sh の型)
        self.assertEqual(len([c for c in self.calls("issue edit") if "--body-file" in c]), 1)

    def test_新しい生き残りだけコメントする(self):
        r = self.report(result(HEAD_B, mutants=[
            {"id": "s0", "file": "Sources/B.swift", "line": 0, "outcome": "survived", "operator": "x", "killers": []},
            {"id": "s9", "file": "Sources/N.swift", "line": 7, "outcome": "survived", "operator": "&& -> ||",
             "killers": []}]))
        self.assertEqual(r.returncode, 0, r.stderr)
        comments = self.comments()
        self.assertEqual(len(comments), 1)
        self.assertIn("s9", comments[0]["body"])
        self.assertIn("Sources/N.swift:7", comments[0]["body"])
        self.assertNotIn("| s0 |", comments[0]["body"], "前の回からの生き残りは新しくない")
        self.assertEqual(state.read_meta(self.issue()["body"])["survivors"], ["s0", "s9"])

    def test_範囲の生き残りは回ごとに新しいのでコメントする(self):
        r = self.report(result(HEAD_B, killed=4, survived=1),
                        ranged=result(HEAD_B, mutants=[{"id": "m0001", "file": "Sources/R.swift", "line": 3,
                                                       "outcome": "survived", "operator": "+ -> -", "killers": []}],
                                      since=HEAD_A), since=HEAD_A)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.comments()), 1)
        self.assertIn("Sources/R.swift:3", self.comments()[0]["body"])

    def test_無効の理由が区画に載る(self):
        self.report(result(HEAD_B, killed=1, invalid=1))
        body = self.issue()["body"]
        self.assertIn("anchor: 原文が 2 回当たる", body)


class UnreadableTest(Env, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.report(result(HEAD_A, killed=3, survived=1))

    def test_読めない束は点数を前回のままにして名乗り_起点を進めない(self):
        for broken, why in ((None, "記録が無い"), ("{", "読めない"),
                            (json.dumps({"version": 1, "counts": {}, "mutants": []}), "counts")):
            with self.subTest(broken=broken):
                r = self.report(broken, result_name="failure")
                self.assertEqual(r.returncode, 0, r.stderr)
                body = self.issue()["body"]
                self.assertIn("**unreadable**", body)
                self.assertIn(why, body)
                self.assertIn("評価 4・殺した 3・生き残り 1", body, "点数の表は前回のまま")
                meta = state.read_meta(body)
                self.assertEqual(meta["range_head"], HEAD_A)
                self.assertEqual(len(meta["history"]), 1, "読めない回を履歴に足さない")
                self.assertEqual(meta["survivors"], ["s0"])

    def test_コメントは読めなくなった回の_1_度だけで_連続は回数だけ書き換える(self):
        self.report(None, result_name="failure")
        self.assertEqual(len(self.comments()), 1)
        self.assertIn("unreadable", self.comments()[0]["body"])
        self.report(None, result_name="failure")
        self.report(None, result_name="failure")
        self.assertEqual(len(self.comments()), 1, "連続の 2 回目以降は黙る")
        self.assertEqual(state.read_meta(self.issue()["body"])["unreadable"], 3)
        self.assertIn("連続 3 回", self.issue()["body"])
        # 読めた回で数え直し、次に読めなくなればまたコメントする
        self.report(result(HEAD_B, killed=5, survived=1))
        self.assertEqual(state.read_meta(self.issue()["body"])["unreadable"], 0)
        self.report(None, result_name="failure")
        self.assertEqual(len(self.comments()), 2)

    def test_範囲を回すつもりだったのに読めなければ_束は更新し_起点は進めない(self):
        r = self.report(result(HEAD_B, killed=4, survived=1), ranged=None, since=HEAD_A, result_name="cancelled")
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("評価 5・殺した 4・生き残り 1", body, "読めた束は更新する")
        self.assertIn("範囲 (since", body)
        self.assertIn("**unreadable**", body)
        meta = state.read_meta(body)
        self.assertEqual(meta["range_head"], HEAD_A, "回しそこなった範囲を飛ばさない")
        self.assertEqual(len(self.comments()), 1)

    def test_形の合わない範囲は_生き残り_0_とは読まない(self):
        bad = result(HEAD_B, since=HEAD_A)
        bad["counts"]["killed"] = 7  # mutants の件数と合わない
        r = self.report(result(HEAD_B, killed=4, survived=1), ranged=bad, since=HEAD_A)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("**unreadable**", body)
        self.assertIn("合わない", body)


class SectionTest(Env, unittest.TestCase):
    def test_begin_だけの壊れた区画は人の文を消さず_末尾に足す(self):
        self.write_store({"issues": [{"number": 7, "title": state.TITLE, "open": True, "labels": [], "type": "Task",
                                      "body": f"人の文 KEEP\n\n{state.BEGIN}\n途中で切れた\n人の続き KEEP2\n"}],
                          "comments": []})
        r = self.report(result(HEAD_A, killed=1, survived=0))
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.read_store()["issues"][0]["body"]
        self.assertIn("人の文 KEEP", body)
        self.assertIn("人の続き KEEP2", body)
        self.assertIn(state.END, body)

    def test_状態の_json_は_HTML_コメントを閉じない(self):
        text = state.encode_meta({"survivors": ["a--b"], "range_head": None})
        self.assertNotIn("--", text[len("<!--"): -len("-->")])
        self.assertEqual(state.read_meta(text)["survivors"], ["a--b"])

    def test_閉じた_Issue_は追跡の対象にしない(self):
        self.report(result(HEAD_A, killed=1))
        data = self.read_store()
        data["issues"][0]["open"] = False
        self.write_store(data)
        self.report(result(HEAD_B, killed=1))
        self.assertEqual(len(self.read_store()["issues"]), 2, "閉じていれば新しく立つ")


class PreviousTest(Env, unittest.TestCase):
    def previous(self, **extra):
        return subprocess.run([sys.executable, str(REPO / "scripts" / "mutation_state.py"), "previous"],
                              capture_output=True, text=True, env=self.env(**extra), cwd=REPO)

    def test_issue_が無ければ何も出さず_0(self):
        r = self.previous()
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_区画が無ければ何も出さず_0(self):
        self.write_store({"issues": [{"number": 7, "title": state.TITLE, "open": True, "labels": [], "type": None,
                                      "body": "人の文だけ"}], "comments": []})
        r = self.previous()
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_書く側が置いた起点を読める(self):
        self.report(result(HEAD_C, killed=1))
        r = self.previous()
        self.assertEqual((r.returncode, r.stdout.strip()), (0, HEAD_C))

    def test_gh_が失敗したら_1_で_何も出さない(self):
        r = self.previous(FAKE_GH_FAIL="1")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")
        self.assertIn("読めなかった", r.stderr)

    def test_commit_に読めない起点は_1_で名乗る(self):
        body = state.BEGIN + "\n" + state.encode_meta({"range_head": "not-a-sha"}) + "\n" + state.END
        self.write_store({"issues": [{"number": 7, "title": state.TITLE, "open": True, "labels": [], "type": None,
                                      "body": body}], "comments": []})
        r = self.previous()
        self.assertEqual(r.returncode, 1)
        self.assertIn("commit に読めない", r.stderr)


if __name__ == "__main__":
    unittest.main()
