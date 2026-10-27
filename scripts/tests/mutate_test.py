#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/mutate.py の検査 (#3221)。

道具は検査の検証力を測る物差しなので、物差しが黙って甘くなる形を 1 件ずつ押さえる:

- **候補はコメントと文字列の中から作らない・変わっていない行から作らない**
- **もとから赤い検査を「殺した」に数えない** (変異なしの回の失敗を差し引く)
- **abort・build の失敗・当たらない原文は `invalid`、期限越えは `timeout`** — どれも点数の分母に入れない
- **関連の suite で検査が飛んだ生き残りは `unevaluated`** — GPU の無い機械で「殺せなかった」と言わない
- **狭い集合で生き残っても、target 全体へ広げてから `survived` と言う**
- **帰属の「単独」は、その提案の検査だけが殺したときだけ数える。表が無い回は名乗る**
- **記録が無い・読めない・形が違う回の要約は `unreadable` で、「生き残り 0」と出さない**
- **回した後、原文は 1 バイトも変わっていない** (書き戻しの退行は人の変更を消す)

`swift` は偽の実行ファイル (下の FAKE_SWIFT) に差し替える。偽物は原文を読んで、どの変異が当たって
いるかで xunit を書き分ける。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "mutate.py"

spec = importlib.util.spec_from_file_location("mutate", SCRIPT)
mutate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mutate)

LIBRARY = textwrap.dedent("""\
    // 比較 a >= b はコメントの中なので候補にしない
    func admits(_ x: Double) -> Bool {
        guard x.isFinite, x >= 0 else { return false }
        let label = "x >= 0 は文字列の中"
        return label.isEmpty == false
    }
    """)

# 偽の swift。Sources/Lib/Lib.swift の原文で振る舞いを決める:
#   `x > 0` / `true else`  → GuardTests/rejectsNegative が赤 (殺す)
#   `BREAK`                → build が落ちる
#   `HANG`                 → build が止まる
#   `CRASH`                → test が記録を残さず 134 で終わる
#   `SKIPPY`               → GuardTests が飛ぶ (GPU の無い機械の形)
#   `isEmpty != false` / `isEmpty == true`
#                          → GuardTests は緑のまま、OtherTests/far が赤 (target 全体でだけ殺す)
#   `CANCELLED`            → GuardTests が Test.cancel で取り消される (xunit では passed のまま・事象の記録にだけ載る)
#   `OTHERCANCEL`          → 関連でない OtherTests が取り消される
#   `UNKEYEDCANCEL`        → testID の欄が無い取り消しが出る
#   `NOEVENTS`             → 事象の記録を書かない
#   いつでも               → BrokenTests/always が赤 (もとから赤い検査)
FAKE_SWIFT = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, re, sys, time
    from pathlib import Path
    args = sys.argv[1:]
    source = Path("Sources/Lib/Lib.swift").read_text()
    if args[:2] == ["package", "dump-package"]:
        print(json.dumps({"targets": [
            {"name": "Lib", "type": "regular", "dependencies": []},
            {"name": "LibTests", "type": "test", "dependencies": [{"byName": ["Lib", None]}]}]}))
        sys.exit(0)
    if args[0] == "build":
        if "HANG" in source:
            time.sleep(60)
        sys.exit(1 if "BREAK" in source else 0)
    if args[0] == "test":
        if "CRASH" in source:
            sys.exit(134)
        pattern = args[args.index("--filter") + 1]
        base = args[args.index("--xunit-output") + 1]
        cases = [("LibTests.GuardTests", "rejectsNegative()"), ("LibTests.OtherTests", "far()"),
                 ("LibTests.BrokenTests", "always()")]
        rows = []
        for classname, name in cases:
            if not re.search(pattern, classname + "/" + name):
                continue
            body = ""
            if classname.endswith("BrokenTests"):
                body = '<failure message="always red"/>'
            elif classname.endswith("GuardTests") and "SKIPPY" in source:
                body = "<skipped>GPU が無い</skipped>"
            elif classname.endswith("GuardTests") and ("x > 0" in source or "true else" in source):
                body = '<failure message="admitted -1"/>'
            elif classname.endswith("OtherTests") and ("isEmpty != false" in source or "isEmpty == true" in source):
                body = '<failure message="far away"/>'
            rows.append('<testcase classname="%s" name="%s">%s</testcase>' % (classname, name, body))
        events_path = args[args.index("--event-stream-output-path") + 1] if "--event-stream-output-path" in args else None
        if events_path and "NOEVENTS" not in source:
            def event(kind, **fields):
                payload = {"kind": kind, "messages": [], "version": 0}
                payload.update(fields)
                return json.dumps({"kind": "event", "payload": payload})
            guard = "LibTests.GuardTests/rejectsNegative()/GuardTests.swift:2:5"
            other = "LibTests.OtherTests/far()/OtherTests.swift:1:1"
            lines = [event("runStarted")]
            if "CANCELLED" in source:
                lines.append(event("testCancelled", testID=guard, _comments=["前提が成り立たない"]))
            if "OTHERCANCEL" in source:
                lines.append(event("testCancelled", testID=other, _comments=["別の前提"]))
            if "UNKEYEDCANCEL" in source:
                lines.append(event("testCancelled", _comments=["どの検査か分からない"]))
            lines.append(event("runEnded"))
            Path(events_path).write_text("\\n".join(lines) + "\\n")
        record = base[:-len(".xml")] + "-swift-testing.xml"
        Path(record).write_text('<?xml version="1.0"?><testsuites><testsuite name="TestResults">'
                                + "".join(rows) + "</testsuite></testsuites>")
        sys.exit(1 if any("failure" in r for r in rows) else 0)
    sys.exit(2)
    """)

GUARD_TEST = textwrap.dedent("""\
    @Suite struct GuardTests {
        @Test func rejectsNegative() { #expect(!admits(-1)) }
    }
    """)


def git(repo, *args):
    """使い捨てのリポジトリの git。手元の署名設定を継がない (temp_repo_signing_test)。"""
    subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@example.com",
                    "-C", str(repo), *args], check=True, capture_output=True)


class Package:
    """偽の swift と、Lib・LibTests を持つ使い捨てのリポジトリ。"""

    def __init__(self, root):
        self.root = Path(root)
        self.repo = self.root / "repo"
        (self.repo / "Sources" / "Lib").mkdir(parents=True)
        (self.repo / "Tests" / "LibTests").mkdir(parents=True)
        (self.repo / "Tests" / "LibTests" / "GuardTests.swift").write_text(GUARD_TEST)
        (self.repo / "Tests" / "LibTests" / "OtherTests.swift").write_text("@Suite struct OtherTests {}\n")
        self.library = self.repo / "Sources" / "Lib" / "Lib.swift"
        self.library.write_text("func admits(_ x: Double) -> Bool { false }\n")
        git(self.repo, "init", "-q")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        self.library.write_text(LIBRARY)
        git(self.repo, "commit", "-qam", "change")
        self.swift = self.root / "swift"
        self.swift.write_text(FAKE_SWIFT)
        self.swift.chmod(0o755)

    def bundle(self, mutants):
        path = self.root / "bundle.json"
        path.write_text(json.dumps({"version": 1, "mutants": mutants}))
        return str(path)

    def run(self, *args, timeout=60):
        env = dict(os.environ, MOKUME_MUTATE_SWIFT=str(self.swift))
        env.pop("GITHUB_STEP_SUMMARY", None)
        out = self.root / "result.json"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "run", "--repo", str(self.repo), "--out", str(out),
             "--no-gpu-slot", "--work", str(self.root / "work"), *args],
            capture_output=True, text=True, env=env, timeout=timeout)
        data = json.loads(out.read_text()) if out.exists() else None
        return result, data


def mutant(ident, find, replace, **extra):
    return {"id": ident, "file": "Sources/Lib/Lib.swift", "find": find, "replace": replace, **extra}


class CandidatesTest(unittest.TestCase):
    def test_comments_and_strings_are_not_candidates(self):
        found = mutate.file_candidates("Lib.swift", LIBRARY, set(range(1, 7)))
        self.assertEqual(sorted({c["line"] for c in found}), [3, 5], found)
        self.assertNotIn(1, {c["line"] for c in found})
        self.assertNotIn(4, {c["line"] for c in found})

    def test_a_guard_clause_can_be_removed(self):
        found = mutate.file_candidates("Lib.swift", LIBRARY, {3})
        mutated = {c["operator"]: c["mutated"].strip() for c in found}
        self.assertEqual(mutated["condition -> true"], "guard x.isFinite, true else { return false }")
        self.assertEqual(mutated[">= -> >"], "guard x.isFinite, x > 0 else { return false }")

    def test_arguments_bindings_and_generics_are_not_clauses(self):
        text = "let a = f(x >= 0)\nlet b: Array<Int> = []\nfunc g() -> Int { 0 }\nif let c = d, c >= 1 {}\n"
        found = mutate.file_candidates("A.swift", text, {1, 2, 3, 4})
        self.assertNotIn("condition -> true", {c["operator"] for c in found if c["line"] in (1, 2, 3)})
        self.assertEqual({c["line"] for c in found if c["line"] in (2, 3)}, set(), found)
        clause = [c["mutated"] for c in found if c["line"] == 4 and c["operator"] == "condition -> true"]
        self.assertEqual(clause, ["if let c = d, true {}"])

    def test_only_lines_the_range_added_become_candidates(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            env = dict(os.environ, MOKUME_MUTATE_SWIFT=str(package.swift))
            out = subprocess.run([sys.executable, str(SCRIPT), "candidates", "--repo", str(package.repo),
                                  "--since", "HEAD"], capture_output=True, text=True, env=env, check=True)
            self.assertEqual(json.loads(out.stdout), [])
            out = subprocess.run([sys.executable, str(SCRIPT), "candidates", "--repo", str(package.repo),
                                  "--since", "HEAD~1"], capture_output=True, text=True, env=env, check=True)
            lines = {c["line"] for c in json.loads(out.stdout)}
            self.assertEqual(lines, {3, 5})

    def test_round_robin_spreads_the_budget_over_files(self):
        self.assertEqual(mutate.round_robin([[1, 2, 3], [4], [5, 6]]), [1, 4, 5, 2, 6, 3])


class BundleTest(unittest.TestCase):
    """束の形だけを見る。原文が当たるかは回したときに `invalid (anchor)` と名乗る (PR を赤くしない)。"""

    def test_the_bundle_is_readable_and_ids_are_unique(self):
        mutants = mutate.load_bundle(REPO / "Tests" / "mutation-bundle.json")
        ids = [m["id"] for m in mutants]
        self.assertEqual(len(ids), len(set(ids)))
        for m in mutants:
            self.assertTrue((REPO / m["file"]).is_file(), m["id"])
            self.assertNotEqual(m["find"], m["replace"], m["id"])
            self.assertIsInstance(m.get("gpu"), bool, m["id"])

    def test_a_misshapen_bundle_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "bundle.json"
            path.write_text(json.dumps({"version": 1, "mutants": [{"id": "a", "file": "f"}]}))
            with self.assertRaises(ValueError):
                mutate.load_bundle(path)


class ClassifyTest(unittest.TestCase):
    RELATED = {"T.GuardTests"}

    def classify(self, cases, build="ok", test="failed", state="ok", baseline=(), gpu=False):
        return mutate.classify(build, test, state, cases, set(baseline), self.RELATED, gpu)

    def test_tests_red_before_the_mutation_do_not_kill(self):
        outcome, _, killers = self.classify([("T.BrokenTests/always()", "failed")],
                                            baseline=["T.BrokenTests/always()"])
        self.assertEqual(outcome, "survived")
        self.assertEqual(killers, [])

    def test_new_failures_are_the_killers(self):
        outcome, _, killers = self.classify([("T.GuardTests/a()", "failed"), ("T.B/b()", "failed")],
                                            baseline=["T.B/b()"])
        self.assertEqual((outcome, killers), ("killed", ["T.GuardTests/a()"]))

    def test_a_vanished_record_is_invalid_not_survived(self):
        for state in ("missing", "unreadable"):
            self.assertEqual(self.classify([], state=state)[0], "invalid")

    def test_build_failure_and_timeout(self):
        self.assertEqual(self.classify([], build="failed", state="missing")[0], "invalid")
        self.assertEqual(self.classify([], build="timeout", state="missing")[0], "timeout")
        self.assertEqual(self.classify([], test="timeout", state="missing")[0], "timeout")

    def test_skipped_related_suite_is_unevaluated(self):
        cases = [("T.GuardTests/a()", "skipped"), ("T.Other/b()", "passed")]
        self.assertEqual(self.classify(cases, test="ok")[0], "unevaluated")
        self.assertEqual(self.classify([("T.Other/b()", "skipped")], test="ok")[0], "survived")
        self.assertEqual(self.classify([("T.Other/b()", "skipped")], test="ok", gpu=True)[0], "unevaluated")

    def test_cancelled_related_suite_is_unevaluated(self):
        # xunit の上では passed のまま、事象の記録の取り消しが cancelled として足されている
        cases = [("T.GuardTests/a()", "passed"), ("T.GuardTests/a()", "cancelled")]
        outcome, reason, _ = self.classify(cases, test="ok")
        self.assertEqual(outcome, "unevaluated")
        self.assertIn("Test.cancel", reason)
        # 関連でない suite の取り消しは、関連の検査が走った回を評価できなかったことにしない
        self.assertEqual(self.classify([("T.Other/b()", "cancelled")], test="ok")[0], "survived")
        self.assertEqual(self.classify([("T.Other/b()", "cancelled")], test="ok", gpu=True)[0], "unevaluated")
        # 殺した回は、取り消しがあっても殺した
        both = [("T.GuardTests/a()", "failed"), ("T.GuardTests/b()", "cancelled")]
        self.assertEqual(self.classify(both)[0], "killed")

    def test_a_cancel_whose_test_is_unknown_counts_as_related(self):
        cases = [("T.Other/b()", "passed"), (mutate.UNKEYED_IDENT, "cancelled")]
        self.assertEqual(self.classify(cases, test="ok")[0], "unevaluated")

    def test_an_unreadable_event_record_is_invalid_not_survived(self):
        outcome, reason, _ = self.classify([("T.GuardTests/a()", "passed")], test="ok", state="事象の記録: 記録が無い")
        self.assertEqual(outcome, "invalid")
        self.assertIn("事象の記録", reason)

    def test_nonzero_exit_without_failures_is_invalid(self):
        self.assertEqual(self.classify([("T.GuardTests/a()", "passed")], test="failed")[0], "invalid")


class AttributionTest(unittest.TestCase):
    def catalog(self, text):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "probe-catalog.tsv"
            path.write_text(text)
            return mutate.read_catalog(path)

    def test_catalog_skips_comments_and_header(self):
        state, rows = self.catalog("# 帰属の表\nsuite\tproposal\tissue\n\nDensityInvarianceTests\tdensity\t3216\n")
        self.assertEqual(state, "present")
        self.assertEqual(rows, {"DensityInvarianceTests": ("density", "3216")})

    def test_malformed_and_missing_catalog_are_named(self):
        self.assertEqual(self.catalog("DensityInvarianceTests density\n")[0], "unreadable")
        self.assertEqual(mutate.read_catalog("/nonexistent/probe-catalog.tsv")[0], "missing")

    def test_sole_counts_only_when_one_proposal_killed_alone(self):
        catalog = {"DensityInvarianceTests": ("density", "3216"), "ModelTests": ("model", "3218")}
        mutants = [
            {"outcome": "killed", "killers": ["MokumeCoreTests.DensityInvarianceTests/a()"]},
            {"outcome": "killed", "killers": ["MokumeCoreTests.DensityInvarianceTests/a()",
                                              "MokumeCoreTests.ShapeTests/b()"]},
            {"outcome": "killed", "killers": ["MokumeCoreTests.Outer/ModelTests/c()"]},
            {"outcome": "survived", "killers": []},
        ]
        totals = mutate.attribute(mutants, "present", catalog)
        self.assertEqual(totals["density"], {"killed": 2, "sole": 1})
        self.assertEqual(totals["model"], {"killed": 1, "sole": 1})
        self.assertEqual(totals["-"], {"killed": 1, "sole": 0})
        self.assertEqual(mutants[1]["sole"], None)

    def test_without_a_catalog_nothing_is_attributed(self):
        mutants = [{"outcome": "killed", "killers": ["T.X/a()"]}]
        self.assertEqual(mutate.attribute(mutants, "missing", {}), {})
        self.assertEqual(mutants[0]["proposals"], [])


class SummaryTest(unittest.TestCase):
    def summary(self, content):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "result.json"
            if content is not None:
                path.write_text(content)
            env = dict(os.environ)
            env["GITHUB_STEP_SUMMARY"] = str(Path(root) / "step-summary.md")
            result = subprocess.run([sys.executable, str(SCRIPT), "summary", str(path)],
                                    capture_output=True, text=True, env=env)
            step = Path(env["GITHUB_STEP_SUMMARY"])
            return result.returncode, result.stdout, step.read_text() if step.exists() else ""

    def assertUnreadable(self, content):
        code, out, step = self.summary(content)
        self.assertEqual(code, 1, out)
        self.assertIn("unreadable", out)
        self.assertIn("unreadable", step)
        self.assertNotIn("生き残り 0", out)

    def test_missing_unreadable_and_misshapen_records_are_named(self):
        self.assertUnreadable(None)
        self.assertUnreadable("")
        self.assertUnreadable("{not json")
        self.assertUnreadable(json.dumps({"version": 1, "counts": {}, "mutants": []}))
        counts = {k: 0 for k in mutate.OUTCOMES}
        self.assertUnreadable(json.dumps({"version": 1, "counts": counts, "mutants": []}))
        counts["killed"] = 2
        self.assertUnreadable(json.dumps({"version": 1, "counts": counts,
                                          "mutants": [{"id": "a", "outcome": "killed"}]}))

    def test_a_readable_result_names_every_count(self):
        counts = dict({k: 0 for k in mutate.OUTCOMES}, killed=1, survived=1, unrun=1)
        mutants = [{"id": "a", "outcome": "killed", "file": "f", "line": 1},
                   {"id": "b", "outcome": "survived", "file": "Sources/X.swift", "line": 9, "operator": ">= -> >"},
                   {"id": "c", "outcome": "unrun", "file": "f"}]
        code, out, step = self.summary(json.dumps({
            "version": 1, "counts": counts, "score": 0.5, "mutants": mutants, "head": "abc",
            "catalog": {"path": "Tests/probe-catalog.tsv", "state": "missing"}}))
        self.assertEqual(code, 0, out)
        self.assertIn("殺した 1・生き残り 1", out)
        self.assertIn("回しきれず 1", out)
        self.assertIn("50.0%", out)
        self.assertIn("`Sources/X.swift:9`", out)
        self.assertIn("missing", out)
        self.assertEqual(out.strip(), step.strip())


class RunTest(unittest.TestCase):
    def test_bundle_outcomes_and_the_source_is_restored(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            before = package.library.read_bytes()
            bundle = package.bundle([
                mutant("kill", "x.isFinite, x >= 0", "x.isFinite, x > 0"),
                mutant("survive", "label.isEmpty == false", "label.isEmpty != true"),
                mutant("build", "x.isFinite, x >= 0", "x.isFinite, x >= 0 BREAK"),
                mutant("crash", "x.isFinite, x >= 0", "x.isFinite, x >= 0 CRASH"),
                mutant("anchor", "not in the file", "x"),
                mutant("gpu", "x.isFinite, x >= 0", "x.isFinite, x >= 0 SKIPPY"),
            ])
            result, data = package.run("--bundle", bundle)
            self.assertEqual(result.returncode, 0, result.stderr)
            outcomes = {m["id"]: m["outcome"] for m in data["mutants"]}
            self.assertEqual(outcomes, {"kill": "killed", "survive": "survived", "build": "invalid",
                                        "crash": "invalid", "anchor": "invalid", "gpu": "unevaluated"})
            killed = next(m for m in data["mutants"] if m["id"] == "kill")
            self.assertEqual(killed["killers"], ["LibTests.GuardTests/rejectsNegative()"])
            self.assertEqual(killed["suites"], ["LibTests.GuardTests"])
            self.assertEqual(data["score"], 0.5)
            self.assertEqual(data["catalog"]["state"], "missing")
            self.assertEqual(package.library.read_bytes(), before)

    def test_a_cancelled_test_is_unevaluated_not_survived(self):
        """変異を入れた回に前提が崩れて取り消した検査は、何も確かめていない (#3348)。"""
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            before = package.library.read_bytes()
            bundle = package.bundle([
                mutant("cancel", "x.isFinite, x >= 0", "x.isFinite, x >= 0 CANCELLED"),
                mutant("other", "x.isFinite, x >= 0", "x.isFinite, x >= 0 OTHERCANCEL"),
                mutant("unkeyed", "x.isFinite, x >= 0", "x.isFinite, x >= 0 UNKEYEDCANCEL"),
                mutant("noevents", "x.isFinite, x >= 0", "x.isFinite, x >= 0 NOEVENTS"),
                mutant("plain", "label.isEmpty == false", "label.isEmpty != true"),
            ])
            result, data = package.run("--bundle", bundle)
            self.assertEqual(result.returncode, 0, result.stderr)
            by_id = {m["id"]: m for m in data["mutants"]}
            self.assertEqual({k: v["outcome"] for k, v in by_id.items()},
                             {"cancel": "unevaluated", "other": "survived", "unkeyed": "unevaluated",
                              "noevents": "invalid", "plain": "survived"})
            self.assertIn("Test.cancel", by_id["cancel"]["reason"])
            self.assertIn("事象の記録", by_id["noevents"]["reason"])
            # 生き残りに数えない
            self.assertEqual(data["counts"]["unevaluated"], 2)
            self.assertEqual(package.library.read_bytes(), before)

    def test_swift_is_asked_for_the_event_stream_in_version_zero(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            calls = Path(root) / "calls.txt"
            wrapper = Path(root) / "swift-logged"
            wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> ' + str(calls) + '\nexec "' + str(package.swift) + '" "$@"\n')
            wrapper.chmod(0o755)
            package.swift = wrapper
            package.run("--bundle", package.bundle([mutant("plain", "label.isEmpty == false", "label.isEmpty != true")]))
            tests = [l for l in calls.read_text().splitlines() if l.startswith("test ")]
            self.assertTrue(tests)
            for line in tests:
                self.assertRegex(line, r"--event-stream-output-path \S+-events\.jsonl --event-stream-version 0")

    def test_timeout_is_counted_and_the_rest_still_runs(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            before = package.library.read_bytes()
            bundle = package.bundle([mutant("hang", "x.isFinite, x >= 0", "x.isFinite, x >= 0 HANG"),
                                     mutant("kill", "x.isFinite, x >= 0", "x.isFinite, x > 0")])
            result, data = package.run("--bundle", bundle, "--timeout", "3")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([m["outcome"] for m in data["mutants"]], ["timeout", "killed"])
            self.assertLess(data["mutants"][0]["seconds"], 30)
            self.assertEqual(package.library.read_bytes(), before)

    def test_budget_leaves_the_rest_unrun(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            bundle = package.bundle([mutant("kill", "x.isFinite, x >= 0", "x.isFinite, x > 0"), mutant("more", "x.isFinite, x >= 0", "x.isFinite, x > 0")])
            result, data = package.run("--bundle", bundle, "--budget", "0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(data["counts"]["unrun"], 2)
            self.assertIsNone(data["score"])

    def test_survivors_of_the_narrow_set_are_tried_on_the_whole_target(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            result, data = package.run("--since", "HEAD~1")
            self.assertEqual(result.returncode, 0, result.stderr)
            by_line = {}
            for m in data["mutants"]:
                by_line.setdefault(m["line"], []).append(m)
            # 3 行目は関連の suite (admits を語で含む GuardTests) だけで殺せる
            for m in (m for m in by_line[3] if m["operator"] in (">= -> >", "condition -> true")):
                self.assertEqual([s["scope"] for s in m["stages"]], ["suites"], m)
                self.assertEqual(m["outcome"], "killed")
            # 5 行目は GuardTests では生き残り、target 全体へ広げて OtherTests が殺す
            for m in by_line[5]:
                self.assertEqual([s["scope"] for s in m["stages"]], ["suites", "targets"], m)
                self.assertEqual(m["stages"][0]["outcome"], "survived")
                self.assertEqual(m["outcome"], "killed")
                self.assertEqual(m["killers"], ["LibTests.OtherTests/far()"])

    def test_local_changes_in_sources_stop_the_run(self):
        with tempfile.TemporaryDirectory() as root:
            package = Package(root)
            package.library.write_text(LIBRARY + "// 手元の変更\n")
            result, data = package.run("--bundle", package.bundle([mutant("kill", "x.isFinite, x >= 0", "x.isFinite, x > 0")]))
            self.assertEqual(result.returncode, 2)
            self.assertIsNone(data)
            self.assertIn("手元の変更", package.library.read_text())


if __name__ == "__main__":
    unittest.main()
