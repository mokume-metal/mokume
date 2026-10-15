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
  2. ci-gate (scripts/ci-gate.sh) は needs の failure と cancelled を赤にし、skipped を素通しに
     しない — PR の run で skipped の検査は、同じ head SHA の skipped を除いた最新の check run が
     success のときだけ通す (#2690)。走っている途中・赤・見つからない・API の失敗は赤で、
     merge_group と、検査が走った run では API を呼ばない。gh は PATH の先の代役で、--jq を
     実際に当てる (絞り込みの誤りを素通りさせない)。check_name で引く前提として、ci-check・
     ci-static という job 名はほかのワークフローに無い

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

**作法の検査は ci.yml に居ない (#2611・#2669)。** タイトル・マージ判定・絵は pr-gate.yml の
必須チェック pr-gate が持つ。ここで固定するのは次の 3 つ:

  9. ci.yml は作法のためのイベント (labeled・unlabeled・pull_request_review) で起きない。
     edited は base の変更のためだけに居る
  10. 段を走らせる 2 つのジョブは、本文・タイトルだけの edited で走らず、base を変えた edited と
      opened / synchronize / reopened・merge_group で走る (`if:` を評価して見る)
  11. ci-gate はコードの検査だけを待ち、ペイロードの可変な欄 (title / body / labels) を読む
      ジョブが ci.yml に無い — 戻すと、直す前の run の赤い ci-gate が同じコミットに残る (#2134)

ワークフローの読み手 (split / needs / condition) は render_workflow_test.py のものを使う
(写しを持たない)。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
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


def evaluate(cond: str, event: str, action=None, base=None) -> bool:
    """`if:` の式を、event・action・changes.base を与えて評価する。

    読めるのは ci.yml が使う形 (`github.event_name`・`github.event.action`・
    `github.event.changes.base` の比較と `||`・`&&`・`!`) だけで、知らない語があれば止まる。
    Actions の式で null と文字列の `!=` は真になる (Python の None != '...' と同じ)。
    """
    names = {
        "github.event_name": repr(event),
        "github.event.action": repr(action),
        "github.event.changes.base": repr(base),
    }
    expr = cond
    for name, value in names.items():
        expr = expr.replace(name, value)
    expr = expr.replace("||", " or ").replace("&&", " and ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    leftover = re.sub(r"'[^']*'|\b(or|and|not|None)\b|[(){}:,!=\s]", "", expr)
    if leftover:
        raise AssertionError(f"if: の式に読めない語がある: {leftover!r} ({cond})")
    return bool(eval(expr, {"__builtins__": {}}, {}))  # noqa: S307 — 上で語を絞った


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

    def test_ci_gate_は判定を_ci_gate_sh_に任せ_check_run_を読める(self):
        gate = self.jobs["ci-gate"]
        self.assertRegex(gate, r"(?m)^        run: bash scripts/ci-gate\.sh\s*$")
        self.assertRegex(gate, r"(?m)^          RESULTS: \$\{\{ toJSON\(needs\) \}\}\s*$")
        # 同じ SHA を引くのは PR の head。合流 ref の SHA (github.sha) には check run が付かない
        self.assertRegex(
            gate, r"(?m)^          HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \}\}\s*$"
        )
        self.assertRegex(gate, r"(?m)^          EVENT_NAME: \$\{\{ github\.event_name \}\}\s*$")
        self.assertRegex(gate, r"(?m)^          GH_TOKEN: \$\{\{ github\.token \}\}\s*$")
        self.assertRegex(gate, r"(?m)^      checks: read\b")
        self.assertRegex(gate, r"(?m)^          sparse-checkout: scripts/ci-gate\.sh\s*$")

    def test_ci_gate_の_timeout_は待ちの期限の外側にある(self):
        # 内側だと、期限の赤 (理由つき) より先に job が切られ、理由の無い cancelled になる
        gate = self.jobs["ci-gate"]
        minutes = int(re.search(r"(?m)^    timeout-minutes: (\d+)\s*$", gate).group(1))
        limit = int(re.search(r"(?m)^WAIT_LIMIT=\$\{WAIT_LIMIT:-(\d+)\}$", GATE.read_text()).group(1))
        self.assertGreater(minutes * 60, limit + 5 * 60)

    def test_段を走らせる_job_の名前はほかのワークフローに無い(self):
        # ci-gate.sh は needs のキーを check run の名前として、check_name で同じ SHA を引く。
        # job に name: があると名前がキーとずれ、同じ名前の job がほかにあると別のワークフローの
        # 結論を読んでしまう
        names = workflow.needs(self.jobs["ci-gate"])
        for name in names:
            with self.subTest(job=name):
                self.assertNotRegex(self.jobs[name], r"(?m)^    name:")
        for path in sorted(CI.parent.glob("*.yml")):
            if path == CI:
                continue
            _, jobs = workflow.split(path.read_text(encoding="utf-8"))
            with self.subTest(workflow=path.name):
                self.assertEqual(set(jobs) & names, set())
                for body in jobs.values():
                    m = re.search(r"(?m)^    name: *['\"]?([^'\"\n]+?)['\"]?\s*$", body)
                    self.assertNotIn(m.group(1) if m else None, names)

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

    # --- 作法の検査は ci.yml に居ない (#2669) ---------------------------------

    def test_作法のためのイベントでは起きない(self):
        top, _ = workflow.split(CI.read_text(encoding="utf-8"))
        triggers = set(re.findall(r"^  ([a-z_]+):", top["on"], re.M))
        self.assertEqual(triggers, {"pull_request", "merge_group"})
        types = re.search(r"(?m)^    types: \[(.*)\]\s*$", top["on"]).group(1)
        self.assertEqual(
            {s.strip() for s in types.split(",")}, {"opened", "synchronize", "reopened", "edited"}
        )

    def test_段を走らせるジョブは作法だけの_edited_で走らず_base_の変更で走る(self):
        cond = workflow.condition(self.jobs["ci-check"])
        runs = {
            "opened": evaluate(cond, "pull_request", "opened"),
            "synchronize": evaluate(cond, "pull_request", "synchronize"),
            "reopened": evaluate(cond, "pull_request", "reopened"),
            "edited (base)": evaluate(cond, "pull_request", "edited", {"ref": {"from": "main"}}),
            "merge_group": evaluate(cond, "merge_group"),
        }
        self.assertEqual([k for k, v in runs.items() if not v], [], "走るべき起動で走らない")
        self.assertFalse(evaluate(cond, "pull_request", "edited"), "本文・タイトルの編集で走る")

    def test_ci_gate_はコードの検査だけを待つ(self):
        self.assertEqual(workflow.needs(self.jobs["ci-gate"]), {"ci-check", "ci-static"})
        for gone in ("pr-title", "review-gate", "drawing-evidence"):
            self.assertNotIn(gone, self.jobs)

    def test_ペイロードの可変な欄を読むジョブが無い(self):
        text = CI.read_text(encoding="utf-8")
        body = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
        for field in ("title", "body", "labels"):
            self.assertNotIn(f"github.event.pull_request.{field}", body, field)


GATE = REPO / "scripts" / "ci-gate.sh"

# gh の代役。呼ばれた引数を $GH_CALLS に書き、check-runs は check_name ごとの JSON に --jq を当てる
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
filter=""
prev=""
url=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  case "$a" in repos/*) url=$a ;; esac
  prev=$a
done
case "$url" in
  */check-runs\\?*)
    # 先頭の CHECKRUNS_FAIL 回だけ落ちる
    n=$(cat "$RUNS_DIR/fails" 2>/dev/null || echo 0)
    if [ "$n" -lt "${CHECKRUNS_FAIL:-0}" ]; then
      echo $((n + 1)) > "$RUNS_DIR/fails"
      echo "gh: HTTP 504: Gateway Timeout" >&2; exit 1
    fi
    name=${url#*check_name=}; name=${name%%&*}
    # 名前ごとの回数。<名前>.after.json があれば、AFTER 回目 (既定 2) からはそちらを返す
    k=$(( $(cat "$RUNS_DIR/$name.count" 2>/dev/null || echo 0) + 1 ))
    echo "$k" > "$RUNS_DIR/$name.count"
    f="$RUNS_DIR/$name.json"
    if [ -f "$RUNS_DIR/$name.after.json" ] && [ "$k" -ge "${AFTER:-2}" ]; then
      f="$RUNS_DIR/$name.after.json"
    fi
    [ -f "$f" ] || f="$RUNS_DIR/none.json"
    # --paginate はページごとに --jq を当てて連結する。2 ページ目があればそれも出す
    jq -r "$filter" < "$f"
    [ ! -f "$RUNS_DIR/$name.2.json" ] || jq -r "$filter" < "$RUNS_DIR/$name.2.json"
    exit 0 ;;
esac
echo "代役が知らない呼び出し: $*" >&2
exit 2
"""

# 時計の代役 (#2713)。sleep は眠らずに $FAKE_CLOCK を引数の秒だけ進めて $SLEEPS に書き、
# date +%s はその時計を返す。時計が進むのは sleep だけなので、期限までの読み直しの回数は
# 負荷にも秒の境目にも依らない。本物の時計 (bash の SECONDS) で測ると、秒の境目の直前に
# 起きた回は WAIT_LIMIT=1 の期限が実時間で 0 秒近くで切れ、1 度しか読まない
FAKE_SLEEP = """#!/bin/bash
printf '%s\\n' "$1" >> "$SLEEPS"
echo $(( $(cat "$FAKE_CLOCK") + $1 )) > "$FAKE_CLOCK"
"""
FAKE_DATE = """#!/bin/bash
[ "$*" = "+%s" ] || { echo "代役が知らない呼び出し: date $*" >&2; exit 2; }
cat "$FAKE_CLOCK"
"""

SHA = "0123abcd"
RESULTS_EDITED = {"ci-check": {"result": "skipped"}, "ci-static": {"result": "skipped"}}


RUN_ID = "555"


def check_run(
    id_: int, status: str, conclusion, app: str = "github-actions", run: str = "1"
) -> dict:
    url = f"https://github.com/o/r/actions/runs/{run}/job/{id_}"
    return {
        "id": id_,
        "status": status,
        "conclusion": conclusion,
        "app": {"slug": app},
        "details_url": url,
        "html_url": url,
    }


def needs_json(results: dict) -> str:
    """toJSON(needs) の形。Actions は 2 空白で字下げし、`"result": "..."` と書く。"""
    return json.dumps(
        {k: {"result": v["result"], "outputs": {}} for k, v in results.items()}, indent=2
    )


class CiGateScriptTest(unittest.TestCase):
    """scripts/ci-gate.sh の判定 (#2690)。"""

    def run_gate(
        self, runs: dict, *, event="pull_request", results=None, env_extra=None, page2=None,
        after=None,
    ):
        """runs = {名前: [check run …]}・page2 = 2 ページ目・after = 読み直したときの応答。

        (returncode, 出力, gh の呼び出し) を返す。既定の WAIT_LIMIT は 0 (1 度だけ読む)。
        時計は代役で、進むのは sleep だけ (POLL_WAIT=0 の既定では進まない)。眠った秒の並びは
        self.sleeps に残す。
        """
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            gh = tmp / "bin" / "gh"
            gh.parent.mkdir()
            for name, text in (("gh", FAKE_GH), ("sleep", FAKE_SLEEP), ("date", FAKE_DATE)):
                (gh.parent / name).write_text(text)
                (gh.parent / name).chmod(0o755)
            clock = tmp / "clock"
            clock.write_text("1700000000\n")
            sleeps = tmp / "sleeps"
            sleeps.write_text("")
            runs_dir = tmp / "runs"
            runs_dir.mkdir()
            (runs_dir / "none.json").write_text(json.dumps({"total_count": 0, "check_runs": []}))
            for name, items in runs.items():
                (runs_dir / f"{name}.json").write_text(
                    json.dumps({"total_count": len(items), "check_runs": items})
                )
            for name, items in (after or {}).items():
                (runs_dir / f"{name}.after.json").write_text(
                    json.dumps({"total_count": len(items), "check_runs": items})
                )
            for name, items in (page2 or {}).items():
                (runs_dir / f"{name}.2.json").write_text(
                    json.dumps({"total_count": len(items), "check_runs": items})
                )
            calls = tmp / "calls"
            calls.write_text("")
            env = {
                "PATH": f"{gh.parent}{os.pathsep}{os.environ.get('PATH', '')}",
                "RESULTS": needs_json(results if results is not None else RESULTS_EDITED),
                "EVENT_NAME": event,
                "HEAD_SHA": SHA,
                "GITHUB_REPOSITORY": "o/r",
                "GITHUB_RUN_ID": RUN_ID,
                "POLL_WAIT": "0",
                "WAIT_LIMIT": "0",
                "GH_CALLS": str(calls),
                "RUNS_DIR": str(runs_dir),
                "FAKE_CLOCK": str(clock),
                "SLEEPS": str(sleeps),
                **(env_extra or {}),
            }
            env = {k: v for k, v in env.items() if v is not None}
            proc = subprocess.run(
                ["/bin/bash", str(GATE)], env=env, capture_output=True, text=True, timeout=30
            )
            # --jq の式は複数行なので、呼び出しの頭 (api …) の行だけを数える
            heads = [ln for ln in calls.read_text().splitlines() if ln.startswith("api ")]
            self.sleeps = [int(s) for s in sleeps.read_text().split()]
            return proc.returncode, proc.stdout + proc.stderr, heads

    def both(self, items):
        return {"ci-check": items, "ci-static": [check_run(900, "completed", "success")]}

    def test_同じ_SHA_の最新が_success_なら通す(self):
        code, out, calls = self.run_gate(self.both([check_run(100, "completed", "success")]))
        self.assertEqual(code, 0, out)
        self.assertEqual(len(calls), 2, calls)
        for call in calls:
            self.assertIn(f"repos/o/r/commits/{SHA}/check-runs?check_name=", call)
            # latest は completed_at の最新だけを返し、走っている途中も古い success も見えない
            self.assertIn("filter=all", call)

    def test_走っている途中なら終わるのを待って結論を返す(self):
        # 変更前の素通しでは、opened の run の ci-check が走っている間に緑が付いた (#2577)。
        # 途中で赤を返すと、後から緑が来ても打ち直すまで PR を塞ぐ (#2690 の実測)
        for final, want in (("success", 0), ("failure", 1)):
            with self.subTest(final=final):
                code, out, calls = self.run_gate(
                    self.both([check_run(100, "in_progress", None)]),
                    after={"ci-check": [check_run(100, "completed", final)]},
                    env_extra={"WAIT_LIMIT": "30", "AFTER": "3"},
                )
                self.assertEqual(code, want, out)
                self.assertIn("待つ", out)
                self.assertGreaterEqual(len(calls), 4, calls)  # ci-check を 3 回・ci-static を 1 回

    # 期限の 2 検査は、本番の既定 (POLL_WAIT=30・WAIT_LIMIT=5400) を片方ずつ渡さずに走らせる。
    # 両方を既定にすると 181 回読み直し、代役の起動だけで秒単位かかる。どちらも ci-check を
    # 0, 1, 2, 3 回眠った時点の 4 回読み、期限に達した 4 回目で赤にする。期限を過ぎた
    # ci-static は 1 度だけ読む

    def test_期限まで終わらなければ赤(self):
        code, out, calls = self.run_gate(
            self.both([check_run(100, "in_progress", None)]),
            env_extra={"POLL_WAIT": None, "WAIT_LIMIT": "90"},
        )
        self.assertEqual(code, 1, out)
        self.assertIn("90 秒待っても結論が出ない", out)
        self.assertIn("走っている途中", out)
        # 期限までは既定の 30 秒おきに読み直し、期限で止まる
        self.assertEqual(self.sleeps, [30, 30, 30])
        self.assertEqual(len(calls), 4 + 1, calls)

    def test_まだ見つからなければ現れるまで待つ(self):
        # 本文の編集が、検査の run の job が作られるより先に届いた場合
        code, out, _ = self.run_gate(
            {"ci-static": [check_run(900, "completed", "success")]},
            after={"ci-check": [check_run(100, "completed", "success")]},
            env_extra={"WAIT_LIMIT": "30"},
        )
        self.assertEqual(code, 0, out)

    def test_最新が赤なら赤(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            with self.subTest(conclusion=conclusion):
                code, out, _ = self.run_gate(self.both([check_run(100, "completed", conclusion)]))
                self.assertEqual(code, 1, out)
                self.assertIn(conclusion, out)

    def test_skipped_しか無ければ赤(self):
        # この run 自身の skipped の check run は数えない
        code, out, _ = self.run_gate(self.both([check_run(300, "completed", "skipped")]))
        self.assertEqual(code, 1, out)
        self.assertIn("走った ci-check が無い", out)

    def test_同じ名前の_check_run_が無ければ赤(self):
        code, out, _ = self.run_gate({"ci-static": [check_run(900, "completed", "success")]})
        self.assertEqual(code, 1, out)
        self.assertIn("走った ci-check が無い", out)

    def test_新しい_skipped_の下の_success_を読む(self):
        runs = self.both([
            check_run(100, "completed", "success"),
            check_run(300, "completed", "skipped"),
        ])
        code, out, _ = self.run_gate(runs)
        self.assertEqual(code, 0, out)

    def test_この_run_自身の_check_run_は読まない(self):
        # skipped の job は ci-gate より遅れて作られ、作られた瞬間は completed でないことがある。
        # それを最新と読むと、後から ci-gate を作る run が無いまま赤が固まる (#2690 の反証)
        runs = self.both([
            check_run(100, "completed", "success"),
            check_run(300, "queued", None, run=RUN_ID),
        ])
        code, out, _ = self.run_gate(runs)
        self.assertEqual(code, 0, out)

    def test_id_は数の大きさで比べる(self):
        runs = self.both([
            check_run(100, "completed", "success"),
            check_run(99, "completed", "failure"),
        ])
        code, out, _ = self.run_gate(runs)
        self.assertEqual(code, 0, out)

    def test_ページをまたいで最新を取る(self):
        code, out, _ = self.run_gate(
            self.both([check_run(100, "completed", "success")]),
            page2={"ci-check": [check_run(200, "in_progress", None)]},
        )
        self.assertEqual(code, 1, out)
        self.assertIn("走っている途中", out)

    def test_最新は作成順_id_で決める(self):
        # 返る並びは id の順とは限らない。古い赤の後に打ち直した緑があれば通し、逆なら赤
        runs = self.both([
            check_run(200, "completed", "success"),
            check_run(100, "completed", "failure"),
        ])
        self.assertEqual(self.run_gate(runs)[0], 0)
        runs = self.both([
            check_run(100, "completed", "success"),
            check_run(200, "completed", "failure"),
        ])
        self.assertEqual(self.run_gate(runs)[0], 1)

    def test_ほかの_app_の_check_run_は読まない(self):
        runs = self.both([
            check_run(100, "completed", "failure"),
            check_run(200, "completed", "success", app="someone-else"),
        ])
        code, out, _ = self.run_gate(runs)
        self.assertEqual(code, 1, out)

    def test_API_が失敗し続けたら理由を出して赤(self):
        code, out, calls = self.run_gate(
            self.both([check_run(100, "completed", "success")]),
            env_extra={"CHECKRUNS_FAIL": "9999", "POLL_WAIT": "1800", "WAIT_LIMIT": None},
        )
        self.assertEqual(code, 1, out)
        self.assertIn("5400 秒待っても結論が出ない", out)
        self.assertIn("Gateway Timeout", out)
        # 既定の 5400 秒の期限までは試し直し、期限で止まる
        self.assertEqual(self.sleeps, [1800, 1800, 1800])
        self.assertEqual(len(calls), 4 + 1, calls)

    def test_API_の一時的な失敗は試し直す(self):
        # 赤を返すと、打ち直すまで PR を塞ぐ
        code, out, _ = self.run_gate(
            self.both([check_run(100, "completed", "success")]),
            env_extra={"CHECKRUNS_FAIL": "2", "WAIT_LIMIT": "30"},
        )
        self.assertEqual(code, 0, out)

    def test_event_が無いか知らなければ赤(self):
        # 開く側に倒れると、ci.yml の渡し忘れひとつで素通しに戻る
        for event in (None, "push"):
            with self.subTest(event=event):
                code, out, calls = self.run_gate(
                    self.both([check_run(100, "completed", "success")]), env_extra={"EVENT_NAME": event}
                )
                self.assertEqual(code, 1, out)
                self.assertEqual(calls, [])

    def test_検査が走った_run_では_API_を呼ばない(self):
        for results, want in (
            ({"ci-check": {"result": "success"}, "ci-static": {"result": "success"}}, 0),
            ({"ci-check": {"result": "failure"}, "ci-static": {"result": "success"}}, 1),
            ({"ci-check": {"result": "cancelled"}, "ci-static": {"result": "skipped"}}, 1),
        ):
            with self.subTest(results=results):
                code, out, calls = self.run_gate({}, results=results)
                self.assertEqual(code, want, out)
                self.assertEqual(calls, [])

    def test_merge_group_では_API_を呼ばない(self):
        code, out, calls = self.run_gate({}, event="merge_group")
        self.assertEqual(code, 0, out)
        self.assertEqual(calls, [])

    def test_最新は作成順で最新の_check_suite_で選ぶ(self):
        """必須は作成順で最新の suite を読む (ci-gate.sh 冒頭の規則・#2577)。古い suite の検査を
        打ち直すと check run の id は最大になるが、読むのは新しい suite の結論 (#2716 の反証 4)。"""
        def in_suite(suite, *args, **kwargs):
            item = check_run(*args, **kwargs)
            item["check_suite"] = {"id": suite}
            return item

        # 古い suite (10) の打ち直しの赤 (id 500) より、新しい suite (20) の緑 (id 300) を読む
        runs = self.both([in_suite(10, 500, "completed", "failure"), in_suite(20, 300, "completed", "success")])
        self.assertEqual(self.run_gate(runs)[0], 0)
        # 逆も同じ。古い suite の打ち直しの緑で、新しい suite の赤を覆わない
        runs = self.both([in_suite(10, 500, "completed", "success"), in_suite(20, 300, "completed", "failure")])
        self.assertEqual(self.run_gate(runs)[0], 1)
        # 同じ suite の中では、打ち直し (後の attempt・id が大きい) の結論を読む
        runs = self.both([in_suite(20, 300, "completed", "failure"), in_suite(20, 400, "completed", "success"),
                          in_suite(10, 500, "completed", "failure")])
        self.assertEqual(self.run_gate(runs)[0], 0)


class EvaluateTest(unittest.TestCase):
    """式の読み手そのものの検査 — 壊れた読み手は、上の検査を黙って緑にする。"""

    def test_比較と論理を読む(self):
        cond = "github.event_name != 'pull_request' || github.event.action != 'edited' || github.event.changes.base"
        self.assertTrue(evaluate(cond, "merge_group"))
        self.assertFalse(evaluate(cond, "pull_request", "edited"))
        self.assertTrue(evaluate(cond, "pull_request", "edited", {"ref": {}}))
        self.assertFalse(evaluate("!(github.event_name == 'merge_group')", "merge_group"))

    def test_知らない語で止まる(self):
        with self.assertRaises(AssertionError):
            evaluate("github.event.pull_request.draft", "pull_request")


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
