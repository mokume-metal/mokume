#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""変異の定期の結果を追跡用の Issue に置く検査 (#3221)。

`scripts/report-mutation.py` (書く側) と `scripts/mutation_state.py` (読む側) を、Issue を持つ偽 gh
で通す。固定するのは:

  1. 追跡用の Issue が無ければ固定タイトルで立て、`verify: triaged` は付けない (着手できる仕事ではない)。
     完全一致で探す (前方一致の別の題を拾わない)。gh の失敗は「無い」と読まず、書かずに 1 で終わる
  2. 在れば本文の機械の区画だけを書き換え、区画の外 (人が書いた文) は触らない。点数の更新ではコメントしない
  3. コメントするのは新しい生き残りだけ。コメントを先に投稿し、成功してから本文を書き換える
  4. 記録が無い・読めない・形が違う・中断した・job が success でない回は `unreadable` と名乗り、「生き残り 0」と
     出さない。点数の表は前回のまま、範囲の起点は進めない。コメントは読めなくなった 1 度目だけ (立てた回も)
  5. 範囲: 候補が 0 件の日は読めた回で起点を進める。unrun が残る間は起点を保ち、評価済みのキーを残す。
     `first` 以外の理由 (missing-commit など) では、束が読めても起点を動かさない
  6. 状態の読み方: CRLF でも読める・メタは区画の中からだけ・区画が 2 つ / メタが壊れている / 型が違うときは
     最初の回に戻さず、作り直してコメントで名乗る
  7. main 以外の run (`--dry-run`) は Issue に何も書かない
  8. 本文は 65536 字の手前に収める。収まらなければ書かない

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
STATE = REPO / "scripts" / "mutation_state.py"
HEAD_A = "a" * 40
HEAD_B = "b" * 40
HEAD_C = "c" * 40

FAKE_GH = r"""#!/usr/bin/env python3
import json, os, re, sys
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
if os.environ.get("FAKE_GH_BAD_LIST") and args[:2] == ["issue", "list"]:
    print('{"not": "a list"}')
    sys.exit(0)
if args[:2] == ["issue", "list"]:
    # GitHub の検索は題の部分一致を含む (完全一致で絞るのは呼び手の仕事)
    wanted = re.match(r'"(.*)" in:title', flag("--search")).group(1)
    print(json.dumps([{"number": i["number"], "title": i["title"]}
                      for i in store["issues"] if i["open"] and wanted in i["title"]]))
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
    if os.environ.get("FAKE_COMMENT_FAIL"):
        sys.exit(1)
    store["comments"].append({"number": int(args[2]), "body": open(flag("--body-file")).read()})
    save()
else:
    sys.exit(1)
"""


def mutant(ident, outcome, key=None, file="Sources/B.swift", line=0):
    m = {"id": ident, "file": file, "line": line, "outcome": outcome, "killers": []}
    if outcome == "survived":
        m["operator"] = ">= -> >"
    if outcome == "invalid":
        m["reason"] = "anchor: 原文が 2 回当たる"
    if key:
        m["key"] = key
    return m


def result(head, killed=0, survived=0, invalid=0, mutants=None, since=None, **extra):
    """mutate.py が書く結果の最小の形。mutants を省けば件数に合わせて作る。"""
    if mutants is None:
        mutants = ([mutant(f"k{i}", "killed", file="Sources/A.swift", line=i) for i in range(killed)]
                   + [mutant(f"s{i}", "survived", line=i) for i in range(survived)]
                   + [mutant(f"i{i}", "invalid", file="Sources/C.swift", line=1) for i in range(invalid)])
    counts = {name: 0 for name in ("killed", "survived", "timeout", "invalid", "unevaluated", "unrun")}
    for m in mutants:
        counts[m["outcome"]] += 1
    scored = counts["killed"] + counts["survived"]
    data = {"version": 1, "head": head, "since": since, "bundle": None if since else "Tests/mutation-bundle.json",
            "candidates": len(mutants), "aborted": None,
            "catalog": {"path": "Tests/probe-catalog.tsv", "state": "present", "rows": 1},
            "seconds": 12.0, "budget": 100, "timeout": 10, "counts": counts,
            "score": round(counts["killed"] / scored, 4) if scored else None,
            "attribution": {"density": {"killed": killed, "sole": 1}} if killed else {}, "mutants": mutants}
    data.update(extra)
    return data


def section_of(meta, extra=""):
    return f"{state.BEGIN}\n{extra}\n{state.encode_meta(meta)}\n{state.END}"


def good_meta(**over):
    meta = {"range_head": HEAD_A, "survivors": [], "unreadable": 0, "history": [], "done": []}
    meta.update(over)
    return meta


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

    def put_issue(self, body, number=7, title=None, open_=True):
        data = self.read_store()
        data["issues"].append({"number": number, "title": title or state.TITLE, "open": open_, "labels": [],
                               "type": "Task", "body": body})
        self.write_store(data)

    def env(self, **extra):
        env = dict(os.environ)
        env.update({"PATH": f"{self.bin}:{env['PATH']}", "FAKE_STORE": str(self.store), "FAKE_LOG": str(self.log),
                    "RUNNER_TEMP": str(self.dir), "MUTATION_REPORT_NOW": "2026-10-31 19:40"})
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "FAKE_GH_FAIL", "FAKE_GH_BAD_LIST",
                    "FAKE_COMMENT_FAIL", "GITHUB_STEP_SUMMARY"):
            env.pop(key, None)
        env.update(extra)
        return env

    def report(self, bundle, ranged=None, since="", reason=None, result_name="success", dry=False, **extra):
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
        argv = [sys.executable, str(REPORT), "--result", result_name, "--bundle", paths[0], "--range", paths[1],
                "--range-since", since]
        if reason is not None:
            argv += ["--range-reason", reason]
        if dry:
            argv.append("--dry-run")
        return subprocess.run(
            argv, capture_output=True, text=True, cwd=REPO,
            env=self.env(GITHUB_RUN_ID=str(self.runs), GITHUB_REPOSITORY="o/r", **extra))

    def issue(self, number=None):
        issues = self.read_store()["issues"]
        if number is None:
            self.assertEqual(len(issues), 1, "追跡用の Issue は 1 本")
            return issues[0]
        return next(i for i in issues if i["number"] == number)

    def meta(self, number=None):
        kind, value = state.parse_state(self.issue(number)["body"])
        self.assertEqual(kind, "ok", value)
        return value

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
        meta = self.meta()
        # 範囲を回すつもりが無かった最初の回は、束が読めれば起点を HEAD に置く
        self.assertEqual(meta["range_head"], HEAD_A)
        self.assertEqual(meta["survivors"], ["s0"])
        self.assertEqual(meta["unreadable"], 0)

    def test_最初の回に読めなければ_unreadable_と名乗って立て_コメントもする(self):
        r = self.report(None)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("unreadable", body)
        self.assertIn("記録が無い", body)
        self.assertNotIn("生き残り 0", body)
        meta = self.meta()
        self.assertIsNone(meta["range_head"], "読めない回は起点を置かない")
        self.assertEqual(meta["unreadable"], 1)
        self.assertEqual(meta["history"], [])
        # 立てた回でも名乗る。次の回は連続なので黙る (指摘 10)
        self.assertEqual(len(self.comments()), 1)
        self.assertIn("unreadable", self.comments()[0]["body"])
        self.report(None)
        self.assertEqual(len(self.comments()), 1)
        self.assertEqual(self.meta()["unreadable"], 2)

    def test_題の前方一致する別の_Issue_を追跡用と読まない(self):
        self.put_issue("別件", number=3, title=state.TITLE + " の続き")
        r = self.report(result(HEAD_A, killed=1))
        self.assertEqual(r.returncode, 0, r.stderr)
        issues = self.read_store()["issues"]
        self.assertEqual(len(issues), 2, "別の題の Issue には書かず、追跡用を立てる")
        self.assertEqual(issues[0]["body"], "別件")
        self.assertEqual(issues[1]["title"], state.TITLE)

    def test_gh_が一覧を読めなければ_無いと読まず_書かずに終わる(self):
        for env in ({"FAKE_GH_FAIL": "1"}, {"FAKE_GH_BAD_LIST": "1"}):
            with self.subTest(env=env):
                r = self.report(result(HEAD_A, killed=1), **env)
                self.assertEqual(r.returncode, 1)
                self.assertIn("読めなかった", r.stderr)
                self.assertEqual(self.read_store()["issues"], [])
                self.assertEqual(self.calls("issue create"), [])


class UpdateTest(Env, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.report(result(HEAD_A, killed=3, survived=1))
        issue = self.issue()
        issue["body"] = issue["body"].replace("定期の job", "人が足した一文 HUMAN 定期の job", 1)
        self.write_store({"issues": [issue], "comments": []})

    def test_点数の更新は区画だけを書き換え_コメントしない(self):
        r = self.report(result(HEAD_B, killed=4, survived=1), ranged=result(HEAD_B, killed=2, since=HEAD_A),
                        since=HEAD_A, reason="ok")
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("人が足した一文 HUMAN", body, "区画の外は触らない")
        self.assertIn("評価 5・殺した 4・生き残り 1", body)
        self.assertIn("評価 2・殺した 2", body, "範囲の表")
        self.assertEqual(self.comments(), [], "同じ生き残り (s0) が続く間は黙る")
        meta = self.meta()
        self.assertEqual(meta["range_head"], HEAD_B)
        self.assertEqual([e["head"] for e in meta["history"]], [HEAD_A[:12], HEAD_B[:12]])
        # 本文を書き換える edit は 1 回だけ (もう 1 回は立てたときの triage.sh の型)
        self.assertEqual(len([c for c in self.calls("issue edit") if "--body-file" in c]), 1)

    def test_新しい生き残りだけコメントする(self):
        r = self.report(result(HEAD_B, mutants=[
            mutant("s0", "survived"), mutant("s9", "survived", file="Sources/N.swift", line=7)]))
        self.assertEqual(r.returncode, 0, r.stderr)
        comments = self.comments()
        self.assertEqual(len(comments), 1)
        self.assertIn("s9", comments[0]["body"])
        self.assertIn("Sources/N.swift:7", comments[0]["body"])
        self.assertNotIn("| s0 |", comments[0]["body"], "前の回からの生き残りは新しくない")
        self.assertEqual(self.meta()["survivors"], ["s0", "s9"])

    def test_範囲の生き残りは回ごとに新しいのでコメントする(self):
        r = self.report(result(HEAD_B, killed=4, survived=1),
                        ranged=result(HEAD_B, mutants=[mutant("m0001", "survived", file="Sources/R.swift", line=3)],
                                      since=HEAD_A), since=HEAD_A, reason="ok")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.comments()), 1)
        self.assertIn("Sources/R.swift:3", self.comments()[0]["body"])

    def test_コメントが先で_落ちたら本文を書き換えず_次の回に重ねて通知する(self):
        survivors = result(HEAD_B, mutants=[mutant("s0", "survived"), mutant("s9", "survived")])
        before = self.issue()["body"]
        r = self.report(survivors, FAKE_COMMENT_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.issue()["body"], before, "コメントが落ちた回は『既知』を本文に残さない")
        self.assertEqual(self.calls("issue edit"), self.calls("issue edit")[:1], "本文の edit は立てたときの型だけ")
        r = self.report(survivors)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("s9", self.comments()[0]["body"])
        self.assertEqual(self.meta()["survivors"], ["s0", "s9"])

    def test_コメントの_post_は_edit_より前に打つ(self):
        self.report(result(HEAD_B, mutants=[mutant("s0", "survived"), mutant("s9", "survived")]))
        lines = [ln for ln in self.log.read_text().splitlines() if ln.startswith(("issue comment", "issue edit"))]
        verbs = [ln.split()[1] for ln in lines]
        self.assertGreater(verbs.index("edit", verbs.index("comment")), verbs.index("comment"))
        self.assertEqual(verbs[-1], "edit")

    def test_無効の理由が区画に載る(self):
        self.report(result(HEAD_B, killed=1, invalid=1))
        self.assertIn("anchor: 原文が 2 回当たる", self.issue()["body"])

    def test_履歴は上限で切れ_新しい生き残りの表も切れる(self):
        history = [{"when": f"d{i}", "head": f"h{i}", "score": 0.5, **{k: 0 for k in
                    ("killed", "survived", "timeout", "invalid", "unevaluated", "unrun")}} for i in range(14)]
        issue = self.issue()
        self.write_store({"issues": [dict(issue, body=state.replace_section(
            issue["body"], section_of(good_meta(history=history))))], "comments": []})
        many = result(HEAD_B, mutants=[mutant(f"s{i}", "survived", line=i) for i in range(40)])
        self.report(many)
        meta = self.meta()
        self.assertEqual(len(meta["history"]), 14, "履歴は 14 行で切る")
        self.assertEqual(meta["history"][0]["when"], "d1")
        comment = self.comments()[0]["body"]
        self.assertIn("ほか 10 件", comment, "コメントの表は 30 行で切る")
        self.assertEqual(comment.count("| 束 |"), 30)


class RangeTest(Env, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.report(result(HEAD_A, killed=3, survived=1))

    def test_候補が_0_件の日は_読めた回で起点を進める(self):
        empty = result(HEAD_B, mutants=[], since=HEAD_A)
        r = self.report(result(HEAD_B, killed=3, survived=1), ranged=empty, since=HEAD_A, reason="ok")
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertNotIn("**unreadable**", body)
        self.assertEqual(self.meta()["range_head"], HEAD_B)
        self.assertIn("候補が 0 件", body)

    def test_回しきれなかった範囲は起点を保ち_評価済みのキーを残す(self):
        partial = result(HEAD_B, since=HEAD_A, mutants=[
            mutant("m1", "killed", key="k1"), mutant("m2", "survived", key="k2"),
            mutant("m3", "unrun", key="k3"), mutant("m4", "unrun", key="k4")])
        r = self.report(result(HEAD_B, killed=3, survived=1), ranged=partial, since=HEAD_A, reason="ok")
        self.assertEqual(r.returncode, 0, r.stderr)
        meta = self.meta()
        self.assertEqual(meta["range_head"], HEAD_A, "回しきるまで起点を進めない")
        self.assertEqual(meta["done"], ["k1", "k2"], "unrun のキーは残さない")
        self.assertIn("積み残し 2 件", self.issue()["body"])
        # 次の回: 残りを回しきれば進めて、done を空にする
        rest = result(HEAD_C, since=HEAD_A, mutants=[mutant("m1", "killed", key="k3"), mutant("m2", "killed", key="k4")])
        self.report(result(HEAD_C, killed=3, survived=1), ranged=rest, since=HEAD_A, reason="ok")
        meta = self.meta()
        self.assertEqual((meta["range_head"], meta["done"]), (HEAD_C, []))

    def test_評価済みのキーは次の回に足され_上限で古い方から落ちる(self):
        issue = self.issue()
        old = [f"o{i}" for i in range(state.DONE_LIMIT)]
        self.write_store({"issues": [dict(issue, body=state.replace_section(
            issue["body"], section_of(good_meta(done=old))))], "comments": []})
        partial = result(HEAD_B, since=HEAD_A, mutants=[mutant("m1", "killed", key="new"),
                                                        mutant("m2", "unrun", key="x")])
        self.report(result(HEAD_B, killed=3, survived=1), ranged=partial, since=HEAD_A, reason="ok")
        done = self.meta()["done"]
        self.assertEqual(len(done), state.DONE_LIMIT)
        self.assertEqual((done[0], done[-1]), ("o1", "new"))

    def test_first_以外の理由では束が読めても起点を動かさない(self):
        for reason in ("missing-commit", "unreadable-issue", "unreadable-state"):
            with self.subTest(reason=reason):
                r = self.report(result(HEAD_B, killed=4, survived=1), reason=reason)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.meta()["range_head"], HEAD_A)
                self.assertIn(reason, self.issue()["body"])
                self.assertIn("**unreadable**", self.issue()["body"])

    def test_範囲のブロックは範囲を回さなかった回も前回のまま残る(self):
        ranged = result(HEAD_B, killed=2, since=HEAD_A)
        self.report(result(HEAD_B, killed=3, survived=1), ranged=ranged, since=HEAD_A, reason="ok")
        self.assertIn("評価 2・殺した 2", self.issue()["body"])
        self.report(result(HEAD_C, killed=3, survived=1), reason="missing-commit")
        body = self.issue()["body"]
        self.assertIn("評価 2・殺した 2", body, "範囲の表を捨てない")
        self.assertIn(HEAD_C[:12], body, "束の表は新しい")

    def test_読めない束は点数を前回のままにして名乗り_起点を進めない(self):
        for broken, why in ((None, "記録が無い"), ("{", "読めない"),
                            (json.dumps({"version": 1, "counts": {}, "mutants": []}), "counts"),
                            (json.dumps(result(HEAD_B, killed=1, aborted="build が timeout")), "中断した")):
            with self.subTest(broken=broken):
                r = self.report(broken, result_name="failure")
                self.assertEqual(r.returncode, 0, r.stderr)
                body = self.issue()["body"]
                self.assertIn("**unreadable**", body)
                self.assertIn(why, body)
                self.assertIn("評価 4・殺した 3・生き残り 1", body, "点数の表は前回のまま")
                meta = self.meta()
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
        self.assertEqual(self.meta()["unreadable"], 3)
        self.assertIn("連続 3 回", self.issue()["body"])
        self.report(result(HEAD_B, killed=5, survived=1))
        self.assertEqual(self.meta()["unreadable"], 0)
        self.report(None, result_name="failure")
        self.assertEqual(len(self.comments()), 2)

    def test_範囲を回すつもりだったのに読めなければ_束は更新し_起点は進めない(self):
        r = self.report(result(HEAD_B, killed=4, survived=1), ranged=None, since=HEAD_A, reason="ok",
                        result_name="cancelled")
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertIn("評価 5・殺した 4・生き残り 1", body, "読めた束は更新する")
        self.assertIn("範囲 (since", body)
        self.assertIn("**unreadable**", body)
        self.assertEqual(self.meta()["range_head"], HEAD_A, "回しそこなった範囲を飛ばさない")
        self.assertEqual(len(self.comments()), 1)

    def test_形の合わない範囲と中断した範囲は_生き残り_0_とは読まない(self):
        bad = result(HEAD_B, since=HEAD_A)
        bad["counts"]["killed"] = 7  # mutants の件数と合わない
        for ranged, why in ((bad, "合わない"), (result(HEAD_B, killed=1, since=HEAD_A, aborted="build が timeout"),
                                                "中断した")):
            with self.subTest(why=why):
                r = self.report(result(HEAD_B, killed=4, survived=1), ranged=ranged, since=HEAD_A, reason="ok")
                self.assertEqual(r.returncode, 0, r.stderr)
                body = self.issue()["body"]
                self.assertIn("**unreadable**", body)
                self.assertIn(why, body)
                self.assertEqual(self.meta()["range_head"], HEAD_A)

    def test_job_の結論が_success_でない回は_記録が読めても名乗る(self):
        for name in ("failure", "cancelled"):
            with self.subTest(result=name):
                r = self.report(result(HEAD_B, killed=4, survived=1), result_name=name)
                self.assertEqual(r.returncode, 0, r.stderr)
                body = self.issue()["body"]
                self.assertIn(f"job の結論が `{name}`", body)
                self.assertIn("job が success で終わらなかった", body)
                self.assertEqual(self.meta()["unreadable"] >= 1, True)
                self.assertIn("評価 5・殺した 4", body, "読めた記録は更新する")
                self.report(result(HEAD_B, killed=4, survived=1))  # 次の回で数え直す


class StateTest(Env, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.report(result(HEAD_A, killed=3, survived=1))

    def test_CRLF_に直された本文でも状態を失わない(self):
        issue = self.issue()
        issue["body"] = issue["body"].replace("\n", "\r\n")
        self.write_store({"issues": [issue], "comments": []})
        r = self.report(result(HEAD_B, killed=4, survived=1))
        self.assertEqual(r.returncode, 0, r.stderr)
        meta = self.meta()
        self.assertEqual(len(meta["history"]), 2, "履歴が最初の回に戻らない")
        self.assertEqual(self.comments(), [], "状態を読めたので作り直しのコメントは出ない")
        self.assertNotIn("\r", self.issue()["body"])

    def test_メタは区画の中からだけ読む(self):
        issue = self.issue()
        stray = state.encode_meta(good_meta(range_head=HEAD_C, survivors=["fake"]))
        issue["body"] = f"人の文に貼られた行:\n{stray}\n\n" + issue["body"]
        self.write_store({"issues": [issue], "comments": []})
        self.assertEqual(state.parse_state(issue["body"])[1]["range_head"], HEAD_A)
        r = self.report(result(HEAD_B, killed=4, survived=1))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.meta()["range_head"], HEAD_B)
        self.assertIn("人の文に貼られた行", self.issue()["body"])

    def test_区画が_2_つ_またはメタが壊れていれば_作り直してコメントで名乗る(self):
        good = self.issue()["body"]
        two = good + "\n\n" + section_of(good_meta(range_head=HEAD_C))
        cases = {
            "two": two,
            "no-meta": good.replace(state.encode_meta(self.meta()), ""),
            "bad-json": good.replace('"unreadable":0', '"unreadable":'),
            "type": good.replace('"survivors":["s0"]', '"survivors":"s0"'),
            "history-type": good.replace('"killed":3', '"killed":"3"'),
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                self.assertEqual(state.parse_state(body)[0], "broken", name)
                issue = dict(self.issue(), body="人の文 KEEP\n\n" + body)
                self.write_store({"issues": [issue], "comments": []})
                r = self.report(result(HEAD_B, killed=4, survived=1))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("Traceback", r.stderr)
                body_now = self.issue()["body"]
                self.assertIn("人の文 KEEP", body_now)
                self.assertEqual(body_now.count(state.BEGIN), 1, "区画は 1 つに作り直す")
                self.assertEqual(self.meta()["range_head"], HEAD_B)
                comments = [c["body"] for c in self.comments()]
                self.assertTrue(any("区画の状態を読めなかった" in c for c in comments), comments)
                self.write_store({"issues": [self.issue()], "comments": []})

    def test_validate_meta_は型を_1_か所で見る(self):
        self.assertIsNone(state.validate_meta(good_meta()))
        for bad in (good_meta(range_head="abc"), good_meta(survivors="x"), good_meta(survivors=[1]),
                    good_meta(unreadable="1"), good_meta(unreadable=True), good_meta(unreadable=-1),
                    good_meta(done="k"), good_meta(history="h"), good_meta(history=[{"when": "d"}]),
                    good_meta(history=[{"when": "d", "head": "h", "score": "x", **{k: 0 for k in state.OUTCOMES}}]),
                    [], "x"):
            with self.subTest(bad=bad):
                self.assertIsNotNone(state.validate_meta(bad))
        self.assertIsNone(state.validate_meta({k: v for k, v in good_meta().items() if k != "done"}))


class SizeTest(Env, unittest.TestCase):
    def test_本文が上限に近ければ表を件数だけにして収める(self):
        self.put_issue("あ" * 58300 + "\n\n" + section_of(good_meta(range_head=HEAD_A)))
        many = result(HEAD_B, mutants=[mutant(f"s{i}", "survived", line=i) for i in range(30)])
        r = self.report(many)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.issue()["body"]
        self.assertLessEqual(len(body), 65536)
        self.assertTrue("ほか 30 件" in body, "表は件数だけになる")

    def test_人の文だけで上限を越えるなら書かずに_1_で終わる(self):
        self.report(result(HEAD_A, killed=1))
        issue = self.issue()
        issue["body"] = "あ" * 70000 + "\n\n" + issue["body"]
        self.write_store({"issues": [issue], "comments": []})
        before = self.issue()["body"]
        r = self.report(result(HEAD_B, killed=1))
        self.assertEqual(r.returncode, 1)
        self.assertIn("収まらない", r.stderr)
        self.assertEqual(self.issue()["body"], before)
        self.assertEqual(self.comments(), [])


class DryRunTest(Env, unittest.TestCase):
    def test_main_以外の_run_は_Issue_に何も書かず_要約に出す(self):
        self.report(result(HEAD_A, killed=3, survived=1))
        before = self.read_store()
        summary = self.dir / "summary.md"
        r = self.report(result(HEAD_B, mutants=[mutant("s0", "survived"), mutant("s9", "survived")]), dry=True,
                        GITHUB_STEP_SUMMARY=str(summary))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read_store(), before, "本文もコメントも変わらない")
        self.assertEqual(len(self.calls("issue create")), 1, "立てたのは最初の回だけ")
        self.assertEqual(len([c for c in self.calls("issue edit") if "--body-file" in c]), 0)
        self.assertEqual(self.calls("issue comment"), [])
        self.assertIn("dry-run", summary.read_text())
        self.assertIn(state.BEGIN, summary.read_text())

    def test_Issue_が無くても_dry_run_は立てない(self):
        r = self.report(result(HEAD_A, killed=3), dry=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls("issue create"), [])


def make_repo(root):
    """a ← b ← main と、a から分かれた side の使い捨ての git。(a, b, side) の commit。"""
    def run(*argv):
        return subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@e.com",
                               "-C", str(root), *argv], check=True, capture_output=True, text=True).stdout.strip()
    run("init", "-q", "-b", "main")
    (root / "f").write_text("a")
    run("add", "-A")
    run("commit", "-qm", "a")
    a = run("rev-parse", "HEAD")
    run("switch", "-qc", "side")
    (root / "f").write_text("side")
    run("commit", "-qam", "side")
    side = run("rev-parse", "HEAD")
    run("switch", "-q", "main")
    (root / "f").write_text("b")
    run("commit", "-qam", "b")
    return a, run("rev-parse", "HEAD"), side


class PreviousTest(Env, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.git = self.dir / "git"
        self.git.mkdir()
        self.a, self.b, self.side = make_repo(self.git)

    def previous(self, **extra):
        out, summary, done = self.dir / "out.txt", self.dir / "sum.md", self.dir / "done.json"
        for p in (out, summary):
            p.write_text("")
        r = subprocess.run([sys.executable, str(STATE), "previous", "--repo-dir", str(self.git), "--done-file",
                            str(done), "--github-output", str(out), "--summary", str(summary)],
                           capture_output=True, text=True, env=self.env(**extra), cwd=REPO)
        outputs = dict(ln.split("=", 1) for ln in out.read_text().splitlines())
        return r, outputs, summary.read_text(), json.loads(done.read_text()) if done.exists() else None

    def test_起点が祖先なら_ok_で_評価済みのキーを渡す(self):
        self.put_issue(section_of(good_meta(range_head=self.a, done=["k1", "k2"])))
        r, outputs, summary, done = self.previous()
        self.assertEqual((r.returncode, r.stdout.strip()), (0, self.a))
        self.assertEqual(outputs, {"since": self.a, "reason": "ok"})
        self.assertEqual(done, ["k1", "k2"])
        self.assertIn("`ok`", summary)

    def test_issue_が無い_区画が無い_起点が無いは_first(self):
        for bodies in ([], ["人の文だけ"], [section_of(good_meta(range_head=None))]):
            with self.subTest(bodies=bodies):
                self.write_store({"issues": [], "comments": []})
                for body in bodies:
                    self.put_issue(body)
                r, outputs, _, done = self.previous()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(outputs, {"since": "", "reason": "first"})
                self.assertEqual(done, [])

    def test_木に無い起点と_祖先でない起点は_missing_commit(self):
        for head in ("f" * 40, self.side):
            with self.subTest(head=head):
                self.write_store({"issues": [], "comments": []})
                self.put_issue(section_of(good_meta(range_head=head)))
                r, outputs, _, _ = self.previous()
                self.assertEqual(r.returncode, 1)
                self.assertEqual(outputs, {"since": "", "reason": "missing-commit"})

    def test_gh_が失敗したら_unreadable_issue(self):
        for env in ({"FAKE_GH_FAIL": "1"}, {"FAKE_GH_BAD_LIST": "1"}):
            with self.subTest(env=env):
                r, outputs, summary, _ = self.previous(**env)
                self.assertEqual(r.returncode, 1)
                self.assertEqual(outputs, {"since": "", "reason": "unreadable-issue"})
                self.assertIn("読めなかった", summary)

    def test_区画があるのに読めなければ_unreadable_state(self):
        self.put_issue(section_of(good_meta()) + "\n" + section_of(good_meta()))
        r, outputs, summary, _ = self.previous()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(outputs, {"since": "", "reason": "unreadable-state"})
        self.assertIn("区画が 2 つ", summary)

    def test_CRLF_の本文からも起点を読める(self):
        self.put_issue(section_of(good_meta(range_head=self.a)).replace("\n", "\r\n"))
        r, outputs, _, _ = self.previous()
        self.assertEqual((r.returncode, outputs["reason"]), (0, "ok"))

    def test_書く側が置いた起点を読める(self):
        self.report(result(self.b, killed=1))
        r, outputs, _, _ = self.previous()
        self.assertEqual((r.returncode, outputs), (0, {"since": self.b, "reason": "ok"}))


if __name__ == "__main__":
    unittest.main()
