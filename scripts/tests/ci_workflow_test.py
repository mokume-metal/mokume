#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/ci.yml` の必須の集約の形と、段の振り分けの検査 (#2589・#2662・#2612)。

release の検査 (`make test-release`) は ci.yml に置かない。merge queue の必須だった頃は
group ごとに約 12 分のホストの macOS を使い、queue の律速の 63% を占めた。いまは版を出す
前の `release.yml` の `release-check` が、版にする SHA そのものを検査する (形の固定は
release_workflow_test.py)。ここで固定するのは次の 2 つ:

  1. ci.yml に test-release が戻っていない — 戻すと、PR か merge_group で macOS の枠を
     また取り合う (2026-10-13 は PR の ci-check が走り出すまで約 1 時間待った)
  2. ci-gate は skipped を通す — 赤にするのは failure と cancelled だけで、PR では走らない
     ジョブ (merge_group だけの段・PR だけの段) が skipped で現れても止まらない

**段の振り分け (#2612)。** CI は `make ci-check` の段を、macOS の ci-check と ubuntu の ci-static に
分けて走らせる (どちらも `make ci-check` を呼び、`CI_CHECK_HOST` で自分の段を選ぶ)。手元の
`make ci-check` は全段のままなので、2 つが合わせて全段にちょうど一致しないと、手元と CI が黙って
食い違う (ADR-0001 原則 8)。ここで固定するのは次の 4 つ:

  3. PR と merge_group のそれぞれで、2 つのジョブの段を合わせると手元の並び (merge_group は
     ci-check が CI_CHECK_SKIP で外す段を除く) にちょうど一致する — 抜けも二重も無い
  4. ビルドの成果物を要する段 (build・test・examples・shaders・params・api・reference) は
     ubuntu へ出ず、合流後の木に当てる 5 段は merge_group の macOS に居る。hooks-test も
     macOS に居る — 検査がスクリプトを /bin/bash (3.2) で起こすことの保証 (#702)
  5. ci-static は ubuntu で走り、ci-check と同じ条件で起動して、ci-gate が両方を待つ
  6. 段を走らせるジョブは `make ci-check` を呼ぶだけで (段の並びを ci.yml に持たない)、
     `CI_CHECK_HOST` の綴りを誤ると全段や 0 段に落ちずに make が止まる

あわせて ci-static の足回りを 2 つ固定する:

  7. 道具は照合値の無いものを 1 つも入れない (ToolPinsTest の冒頭)
  8. ubuntu へ出したシェルの段のスクリプトには、macOS の hooks-test に `/bin/bash` で起こす
     検査がある (StaticShellStepsTest の冒頭)

段の集合は Makefile を正本にして、**ci-check のレシピをそのまま走らせて**読む。レシピは
`bash scripts/ci-check.sh <段…>` なので、PATH の先に置いた代役の `bash` が受け取った引数を
書き出して抜ける (駆動役も段も走らない)。各ジョブの `CI_CHECK_HOST` と `CI_CHECK_SKIP` は
ci.yml から読む。並びの写しをここに持たない。

ワークフローの読み手 (split / needs / condition) は render_workflow_test.py のものを使う
(写しを持たない)。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
CI = REPO / ".github" / "workflows" / "ci.yml"
MAKE = shutil.which("make")

# 組み上げの成果物を要する段。ubuntu (Swift も Metal も無い) では走らない
NEEDS_BUILD = {"build", "test", "examples", "shaders", "params", "api", "reference"}
# merge_group の合流後の木に当てる段 (#2612 完了条件 5)。render が見ない検査で、合流して初めて
# 赤になる組み合わせを拾うのは merge queue の役目である (ci.yml の ci-check のコメント)
AFTER_MERGE = {"examples", "shaders", "params", "api", "reference"}

# 代役の bash。レシピの `bash scripts/ci-check.sh <段…>` を受け、引数を 1 行ずつ出す
STUB_BASH = '#!/bin/sh\nfor a in "$@"; do printf \'%s\\n\' "$a"; done\n'

# 外の make と CI のジョブから継ぐ指定。hooks-test は CI の ci-check の中で走り、そこでは
# CI_CHECK_HOST が macos で、merge_group では CI_CHECK_SKIP が `build test` で立っている
INHERITED = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "CI_CHECK_SKIP", "CI_CHECK_HOST")


def run_ci_check(host: str, skip: str) -> subprocess.CompletedProcess:
    """`make ci-check CI_CHECK_HOST=<host> CI_CHECK_SKIP=<skip>` を、代役の bash の下で走らせる。"""
    with tempfile.TemporaryDirectory() as tmp:
        stub = Path(tmp) / "bash"
        stub.write_text(STUB_BASH)
        stub.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k not in INHERITED}
        env["PATH"] = f"{tmp}{os.pathsep}{env.get('PATH', '')}"
        return subprocess.run(
            [MAKE, "--no-print-directory", "-s", "ci-check",
             f"CI_CHECK_HOST={host}", f"CI_CHECK_SKIP={skip}"],
            cwd=REPO, env=env, capture_output=True, text=True, timeout=60,
        )


def planned_steps(host: str, skip: str) -> list[str]:
    """`make ci-check` が CI_CHECK_HOST=<host>・CI_CHECK_SKIP=<skip> で駆動役へ渡す段の並び。"""
    result = run_ci_check(host, skip)
    if result.returncode != 0:
        raise AssertionError(f"make ci-check (CI_CHECK_HOST={host!r}) が落ちた: {result.stderr}")
    lines = result.stdout.split()
    if not lines or lines[0] != "scripts/ci-check.sh":
        raise AssertionError(
            f"make ci-check が駆動役 (scripts/ci-check.sh) を呼んでいない: {result.stdout!r}"
        )
    return lines[1:]


def host_of(body: str) -> str:
    """ジョブが make ci-check へ渡す CI_CHECK_HOST。無ければ空 (= 全段)。"""
    m = re.search(r"(?m)^\s+CI_CHECK_HOST: (\S+)\s*$", body)
    return m.group(1) if m else ""


def skip_of(body: str, event: str) -> str:
    """ジョブがその event で make ci-check へ渡す CI_CHECK_SKIP。無ければ空。"""
    m = re.search(r"(?m)^\s+CI_CHECK_SKIP: (.+?)\s*$", body)
    if not m:
        return ""
    q = re.fullmatch(
        r"\$\{\{ github\.event_name == 'merge_group' && '([^']*)' \|\| '' \}\}", m.group(1)
    )
    if not q:
        raise AssertionError(f"CI_CHECK_SKIP の形を読めない: {m.group(1)}")
    return q.group(1) if event == "merge_group" else ""


class CiWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.jobs = workflow.split(CI.read_text(encoding="utf-8"))

    def test_test_release_は_ci_yml_に無い(self):
        self.assertNotIn("test-release", self.jobs)
        self.assertNotIn("test-release", workflow.needs(self.jobs["ci-gate"]))
        for name, body in self.jobs.items():
            with self.subTest(job=name):
                self.assertNotIn("make test-release", body)

    def test_ci_gate_は_skipped_を通す(self):
        gate = self.jobs["ci-gate"]
        # skipped を赤にすると、PR の ci-gate が毎回落ちる
        self.assertIn("(failure|cancelled)", gate)
        self.assertNotIn("skipped", gate.split("run: |", 1)[1])

    def test_ci_static_は_ubuntu_で_make_ci_check_を呼ぶだけ(self):
        body = self.jobs["ci-static"]
        self.assertRegex(body, r"(?m)^    runs-on: ubuntu-")
        self.assertEqual(re.findall(r"make [a-z-]+", body), ["make ci-check"])
        self.assertEqual(host_of(body), "ubuntu")

    def test_ci_check_は_macOS_で_make_ci_check_を呼ぶだけ(self):
        body = self.jobs["ci-check"]
        self.assertRegex(body, r"(?m)^    runs-on: macos-")
        self.assertEqual(re.findall(r"make [a-z-]+", body), ["make ci-check"])
        self.assertEqual(host_of(body), "macos")

    def test_段を走らせる_2_つのジョブは同じ条件で起動する(self):
        # 片方だけが merge_group やラベルの付け外しで走らないと、その event の段が抜ける
        self.assertTrue(workflow.condition(self.jobs["ci-check"]))
        self.assertEqual(
            workflow.condition(self.jobs["ci-static"]), workflow.condition(self.jobs["ci-check"])
        )

    def test_ci_gate_は段を走らせる_2_つのジョブを待つ(self):
        self.assertTrue({"ci-check", "ci-static"} <= workflow.needs(self.jobs["ci-gate"]))


@unittest.skipUnless(MAKE, "make が PATH に無い")
class StepPartitionTest(unittest.TestCase):
    """手元の全段を、CI の 2 つのジョブが抜けも二重も無く分け持つ (#2612)。"""

    @classmethod
    def setUpClass(cls):
        _, jobs = workflow.split(CI.read_text(encoding="utf-8"))
        macos, static = jobs["ci-check"], jobs["ci-static"]
        # merge_group で外す段は ci-check の CI_CHECK_SKIP が決める (#1985)
        cls.events = {event: skip_of(macos, event) for event in ("pull_request", "merge_group")}
        cls.local = planned_steps("", "")
        cls.plans = {
            event: (
                planned_steps(host_of(macos), skip_of(macos, event)),
                planned_steps(host_of(static), skip_of(static, event)),
            )
            for event in cls.events
        }

    def test_手元の_ci_check_は全段を走らせる(self):
        # 段名の正本は Makefile。ここでは並びに重複が無く、ビルドを要する段を含むことだけを見る
        self.assertEqual(len(self.local), len(set(self.local)), self.local)
        self.assertTrue(NEEDS_BUILD <= set(self.local), self.local)

    def test_2_つのジョブを合わせると手元の並びにちょうど一致する(self):
        for event, skip in self.events.items():
            with self.subTest(event=event):
                macos, static = self.plans[event]
                expected = [s for s in self.local if s not in skip.split()]
                self.assertEqual(sorted(set(macos) & set(static)), [], f"{event}: 二重に走る段")
                missing = [s for s in expected if s not in macos and s not in static]
                self.assertEqual(missing, [], f"{event}: どちらのジョブでも走らない段")
                extra = [s for s in macos + static if s not in expected]
                self.assertEqual(extra, [], f"{event}: 手元の並びに無い段")
                # 並びの順も崩さない (落ちたらそこで止まる並びの意味は Makefile が持つ)
                self.assertEqual(macos, [s for s in expected if s in macos])
                self.assertEqual(static, [s for s in expected if s in static])

    def test_ビルドを要する段は_ubuntu_へ出ない(self):
        for event in self.events:
            with self.subTest(event=event):
                _, static = self.plans[event]
                self.assertEqual(sorted(NEEDS_BUILD & set(static)), [])

    def test_合流後の木に当てる段は_merge_group_の_macOS_に居る(self):
        macos, _ = self.plans["merge_group"]
        self.assertEqual(sorted(AFTER_MERGE - set(macos)), [])

    def test_hooks_test_は_macOS_に居る(self):
        # 検査がスクリプトを /bin/bash (3.2) で起こすことの保証 (#702) は macOS でしか成り立たない
        for event in self.events:
            with self.subTest(event=event):
                macos, _ = self.plans[event]
                self.assertIn("hooks-test", macos)

    def test_merge_group_で外すのは_build_と_test_だけ(self):
        # 外す段が増えると、合流後の木で誰も走らせない段が黙って生まれる
        self.assertEqual(sorted(self.events["merge_group"].split()), ["build", "test"])

    def test_CI_CHECK_HOST_の綴りを誤ると止まる(self):
        # 全段や 0 段へ黙って落ちると、そのジョブの段が抜けるか二重になる
        result = run_ci_check("linux", "")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CI_CHECK_HOST", result.stderr)
        self.assertNotIn("scripts/ci-check.sh", result.stdout)


def requirements(path: Path) -> tuple[list[str], dict[str, list[str]]]:
    """requirements の (指定の行, 名前==版 → 照合値の並び)。継続行 (`\\`) は 1 つに畳む。"""
    text = re.sub(r"\\\n", " ", path.read_text(encoding="utf-8"))
    options, pins = [], {}
    for line in text.splitlines():
        line = line.split(" #", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("--"):
            options.append(" ".join(line.split()))
            continue
        name = line.split()[0]
        pins[name] = re.findall(r"--hash=sha256:([0-9a-f]{64})", line)
    return options, pins


class ToolPinsTest(unittest.TestCase):
    """ci-static は照合値の無いものを 1 つも入れない (#2612)。

    `--require-hashes` は build 依存に効かない。sdist を組むと、組む道具 (build-system の
    requires) が版も照合値も無しに隔離環境へ入る。だからホイールだけを許し (`--only-binary
    :all:`)、合うホイールの無い reuse だけを例外にして、組む道具は照合値つきで先に入れて
    `--no-build-isolation` で使わせる。
    """

    TOOLS = REPO / "scripts" / "ci-tools.txt"
    BUILD = REPO / "scripts" / "ci-tools-build.txt"

    @classmethod
    def setUpClass(cls):
        _, jobs = workflow.split(CI.read_text(encoding="utf-8"))
        cls.installs = re.findall(r"(?m)^\s+(\S*pip\"? install .+)$", jobs["ci-static"])

    def test_全部の版に照合値がある(self):
        for path in (self.TOOLS, self.BUILD):
            options, pins = requirements(path)
            with self.subTest(file=path.name):
                self.assertTrue(pins)
                for name, hashes in pins.items():
                    self.assertRegex(name, r"^[A-Za-z0-9._-]+==\S+$", "版を == で固定する")
                    self.assertTrue(hashes, f"{name} に照合値が無い")
                self.assertIn("--require-hashes", options)
                self.assertIn("--only-binary :all:", options)

    def test_sdist_から組むのは_reuse_だけ(self):
        tools, _ = requirements(self.TOOLS)
        self.assertEqual([o for o in tools if o.startswith("--no-binary")], ["--no-binary reuse"])
        build, _ = requirements(self.BUILD)
        self.assertEqual([o for o in build if o.startswith("--no-binary")], [])

    def test_ci_static_は組む道具を先に入れ_隔離せずに組む(self):
        self.assertEqual(len(self.installs), 2, self.installs)
        first, second = self.installs
        self.assertIn("-r scripts/ci-tools-build.txt", first)
        self.assertIn("-r scripts/ci-tools.txt", second)
        self.assertIn("--no-build-isolation", second)
        for line in self.installs:
            self.assertIn("--require-hashes", line)


@unittest.skipUnless(MAKE, "make が PATH に無い")
class StaticShellStepsTest(unittest.TestCase):
    """ubuntu へ出したシェルの段は、macOS の hooks-test が `/bin/bash` で起こす (#2612・#702)。

    CI ではこれらの段が ubuntu の bash 5 と GNU の道具で走る。手元とエージェントが走らせる
    `/bin/bash` (3.2) と BSD の道具での動きは、macOS に残る hooks-test の検査だけが持つ。
    段のレシピが起こす `scripts/*.sh` ごとに、そのスクリプトを名指しし `/bin/bash` を起こす
    検査が scripts/tests に在ることを見る (Makefile の CI_STATIC_STEPS の注釈の約束)。
    """

    def test_ubuntu_のシェルの段には_bin_bash_の検査がある(self):
        static = planned_steps("ubuntu", "")
        env = {k: v for k, v in os.environ.items() if k not in INHERITED}
        tests = {
            p.name: p.read_text(encoding="utf-8")
            for p in (REPO / "scripts" / "tests").glob("*_test.py")
        }
        scripts = set()
        for step in static:
            recipe = subprocess.run(
                [MAKE, "--no-print-directory", "-n", step],
                cwd=REPO, env=env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(recipe.returncode, 0, recipe.stderr)
            scripts |= set(re.findall(r"scripts/([\w.-]+\.sh)\b", recipe.stdout))
        self.assertTrue(scripts, "ubuntu の段にシェルのスクリプトが 1 つも無い (読み方が壊れている)")
        uncovered = sorted(
            s for s in scripts
            if not any(s in text and '"/bin/bash"' in text for text in tests.values())
        )
        self.assertEqual(uncovered, [], "ubuntu へ出したのに /bin/bash で起こす検査の無いスクリプト")


if __name__ == "__main__":
    unittest.main()
