#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""定期の「例の絵の前後の比較」(#2706) の検査。

#2705 では、render-pr が名指しした 13 枚の画素のずれが merge の後に誰の手元にも残らず、
11 日後に無関係の作業で偶然見つかった。定期の run が、前回までに比べ終えた main の SHA から
今の main までの区間を描き比べ、名指しがあれば既存の起票の経路で知らせる。部品は 3 つで、
それぞれ固定するのは次のとおり:

`scripts/drift-base.sh` (起点を引く。GitHub ホストの門番の job)

  1. 起点は、**`scheduled-drift` の job が success で終わった最後の定期の run** の head SHA。
     run 全体の結論は見ない — 比べる job が落ちた回は起点にならず (区間が閉じていない)、
     debug が赤でも比べる job が success なら起点になる
  2. 今の run 自身は数えない
  3. 比べ終えた回が無ければ `reason=none`、API が読めなければ `reason=api` (黙って空にしない)

`scripts/scheduled-drift.sh` (描くか決めて描く。専用機の job)

  4. 起点が無いとき (初回・API の失敗) は描かず、その旨を run の要約と記録へ書く。
     初回は success (この回が次の起点)、API の失敗と起点を受け取れなかった回は赤 (起点が動かない)
  5. 区間が空・描画のパスに触れた変更が無い・起点の commit が remote から消えたときは、描かずに
     理由を書いて success。起点の取得そのものが失敗した回 (ネットワーク・認証) は、区間を捨てず赤
  6. 描画のパスに触れた変更があれば `example-shots.py --drift <起点> --drift-record` を呼び、
     変わった絵の本数を `drift-count` へ出す

`scripts/report-example-drift.sh` (起票)

  7. 変わった絵が 1 本以上あれば固定タイトルで起票し、本文にファイル・`snippet=`・違う画素・
     最大の差の表と区間の比較の URL を載せる。0 本なら起票しない。記録が落ちていても、
     専用機の job が名乗った本数があれば起票する (名指しを握りつぶさない)
  8. 同じ絵が名指しされ続ける間はコメントせず、別の絵が加われば知らせる
     (report_check_failure_test.py の test_example_drift)

偽 gh は PATH の先頭に置いた同型のスタブで、--jq は jq で実際に適用する。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE_SCRIPT = REPO / "scripts" / "drift-base.sh"
DRIFT_SCRIPT = REPO / "scripts" / "scheduled-drift.sh"
REPORT_SCRIPT = REPO / "scripts" / "report-example-drift.sh"

TITLE = "fix(docs): 実装の変更で画素が変わった例の絵が、撮り直されないまま残っている"

# 偽 gh。drift-base.sh が読む 2 本の REST だけに答える。
#   gh api repos/…/workflows/render.yml/runs?…     … $FAKE_DIR/runs.json (FAKE_RUNS_FAIL で落ちる)
#   gh api repos/…/actions/runs/<id>/jobs?…        … $FAKE_DIR/jobs-<id>.json (無ければ落ちる)
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
[ "$1" = api ] || exit 1
path=$2
query=
prev=
for a in "$@"; do
  [ "$prev" = "--jq" ] && query=$a
  prev=$a
done
case "$path" in
  */workflows/render.yml/runs\\?*)
    [ -z "${FAKE_RUNS_FAIL:-}" ] || exit 1
    file=$FAKE_DIR/runs.json ;;
  */actions/runs/*/jobs\\?*)
    id=${path#*/actions/runs/}
    id=${id%%/*}
    file=$FAKE_DIR/jobs-$id.json
    [ -f "$file" ] || exit 1 ;;
  *) exit 1 ;;
esac
jq -r "$query" "$file"
"""


def sh(*args, cwd, env=None):
    done = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=False)
    return done


class DriftBaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.bin_dir = bin_dir
        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.output = self.dir / "github-output"

    def runs(self, *runs):
        """新しい順の (id, head_sha)。"""
        data = {"workflow_runs": [{"id": i, "head_sha": sha} for i, sha in runs]}
        (self.dir / "runs.json").write_text(json.dumps(data))

    def jobs(self, run_id, **conclusions):
        """run の job の結論。名前は `scheduled_drift` → `scheduled-drift`。"""
        data = {"jobs": [{"name": k.replace("_", "-"), "conclusion": v} for k, v in conclusions.items()]}
        (self.dir / f"jobs-{run_id}.json").write_text(json.dumps(data))

    def pick(self, run_id="900", **env_extra):
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_DIR": str(self.dir),
                "FAKE_GH_LOG": str(self.log),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
                "GITHUB_RUN_ID": run_id,
                "GITHUB_OUTPUT": str(self.output),
                **env_extra,
            }
        )
        self.output.write_text("")
        done = sh("/bin/bash", str(BASE_SCRIPT), cwd=REPO, env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        out = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        return out["base"], out["reason"]

    def test_比べる_job_が_success_で終わった最後の_run_の_SHA_を起点にする(self):
        self.runs((800, "c" * 40), (700, "b" * 40), (600, "a" * 40))
        self.jobs(800, scheduled_debug="success")  # 比べる job が無い (この機構より前の run)
        self.jobs(700, scheduled_drift="failure")  # 比べる job が落ちた — 区間が閉じていない
        self.jobs(600, scheduled_drift="success", scheduled_debug="failure")
        # run 全体が赤でも、比べる job が success なら起点になる
        self.assertEqual(self.pick(), ("a" * 40, ""))

    def test_今の_run_自身は数えない(self):
        self.runs((900, "d" * 40), (800, "c" * 40))
        self.jobs(900, scheduled_drift="success")
        self.jobs(800, scheduled_drift="success")
        self.assertEqual(self.pick(run_id="900"), ("c" * 40, ""))

    def test_切れた回と_skipped_の回は起点にならない(self):
        self.runs((800, "c" * 40), (700, "b" * 40), (600, "a" * 40))
        self.jobs(800, scheduled_drift="cancelled")
        self.jobs(700, scheduled_drift="skipped")
        self.jobs(600, scheduled_drift="success")
        self.assertEqual(self.pick(), ("a" * 40, ""))

    def test_比べ終えた回が無ければ_none(self):
        self.runs((800, "c" * 40), (700, "b" * 40))
        self.jobs(800, scheduled_drift="failure")
        self.jobs(700, scheduled_debug="success")
        self.assertEqual(self.pick(), ("", "none"))

    def test_定期の_run_が_1_本も無ければ_none(self):
        self.runs()
        self.assertEqual(self.pick(), ("", "none"))

    def test_run_の一覧を読めなければ_api(self):
        self.runs((800, "c" * 40))
        self.assertEqual(self.pick(FAKE_RUNS_FAIL="1"), ("", "api"))

    def test_job_を読めなければ_api(self):
        self.runs((800, "c" * 40))  # jobs-800.json が無い → 偽 gh が落ちる
        self.assertEqual(self.pick(), ("", "api"))


class ScheduledDriftTest(unittest.TestCase):
    """実物の git の木と、偽の example-shots.py で走らせる。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.repo = self.dir / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.commits = [self.commit("README.md", "a\n")]
        self.called = self.dir / "example-shots.args"
        # 偽の example-shots.py: 引数を残し、FAKE_DRIFT_ROWS の行を記録へ書く
        self.fake = self.dir / "fake-example-shots.py"
        self.fake.write_text(
            "import os, pathlib, sys\n"
            "pathlib.Path(os.environ['FAKE_ARGS_OUT']).write_text(' '.join(sys.argv[1:]) + '\\n')\n"
            "record = pathlib.Path(sys.argv[sys.argv.index('--drift-record') + 1])\n"
            "record.mkdir(parents=True, exist_ok=True)\n"
            "(record / 'summary.md').write_text('## 例の絵の前後の比較\\n\\n表\\n')\n"
            "rows = os.environ.get('FAKE_DRIFT_ROWS', '')\n"
            "(record / 'drifts.tsv').write_text(rows)\n"
        )
        self.output = self.dir / "github-output"
        self.summary = self.dir / "step-summary"

    def git(self, *args):
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.com",
        }
        done = sh("git", "-c", "commit.gpgsign=false", *args, cwd=self.repo, env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def commit(self, path, text):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"change {path}")
        return self.git("rev-parse", "HEAD")

    def run_drift(self, base="", reason="", rows="", expect=0):
        env = {
            **os.environ,
            "DRIFT_BASE": base,
            "DRIFT_BASE_REASON": reason,
            "EXAMPLE_SHOTS": str(self.fake),
            "FAKE_ARGS_OUT": str(self.called),
            "FAKE_DRIFT_ROWS": rows,
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_STEP_SUMMARY": str(self.summary),
        }
        self.output.write_text("")
        self.summary.write_text("")
        if self.called.exists():
            self.called.unlink()
        done = sh("/bin/bash", str(DRIFT_SCRIPT), cwd=self.repo, env=env)
        self.assertEqual(done.returncode, expect, done.stderr + done.stdout)
        out = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        record = self.repo / ".build" / "scheduled-drift"
        return out.get("drift-count"), self.summary.read_text(), record

    def test_起点が無い初回は描かず要約に書き_success_で終わる(self):
        count, summary, record = self.run_drift(reason="none")
        self.assertEqual(count, "0")
        self.assertIn("見つからない", summary)
        self.assertIn("比べない", summary)
        self.assertFalse(self.called.exists())
        self.assertIn("見つからない", (record / "summary.md").read_text())
        self.assertEqual((record / "drifts.tsv").read_text(), "")

    def test_API_を読めなかった回は描かず要約に書き赤で終わる(self):
        count, summary, _ = self.run_drift(reason="api", expect=1)
        self.assertEqual(count, "0")
        self.assertIn("API", summary)
        self.assertFalse(self.called.exists())

    def test_起点を受け取れなかった回も描かず赤で終わる(self):
        count, summary, _ = self.run_drift(reason="", expect=1)
        self.assertEqual(count, "0")
        self.assertIn("受け取れなかった", summary)
        self.assertFalse(self.called.exists())

    def test_区間が空なら描かない(self):
        count, summary, _ = self.run_drift(base=self.commits[0])
        self.assertEqual(count, "0")
        self.assertIn("区間が空", summary)
        self.assertFalse(self.called.exists())

    def test_描画のパスに触れていない区間は描かない(self):
        base = self.commits[0]
        self.commit("docs/guide.md", "文書だけ\n")
        count, summary, _ = self.run_drift(base=base)
        self.assertEqual(count, "0")
        self.assertIn("触れた変更が無い", summary)
        self.assertFalse(self.called.exists(), "描画に触れていない区間で、例の絵を描いた")

    def test_起点が_remote_から消えていれば描かず_success_で終わり区間を捨てる(self):
        # 到達できない起点を持ち続けると、起点が動かず毎回落ちる。取得の失敗とは分ける
        origin = self.dir / "origin.git"
        sh("git", "init", "-q", "--bare", str(origin), cwd=self.dir)
        self.git("remote", "add", "origin", str(origin))
        self.commit("Sources/MokumeCore/A.swift", "x\n")
        count, summary, _ = self.run_drift(base="f" * 40)
        self.assertEqual(count, "0")
        self.assertIn("remote に無い", summary)
        self.assertFalse(self.called.exists())

    def test_取得そのものが失敗した回は区間を捨てず赤で終わる(self):
        # origin に届かない (ネットワーク・認証の失敗と同じ形)。success にすると、この区間の名指しが黙って消える
        self.git("remote", "add", "origin", str(self.dir / "no-such-origin.git"))
        self.commit("Sources/MokumeCore/A.swift", "x\n")
        count, summary, _ = self.run_drift(base="f" * 40, expect=1)
        self.assertEqual(count, "0")
        self.assertIn("取得の失敗", summary)
        self.assertIn("赤で終わり", summary)
        self.assertFalse(self.called.exists())

    def test_描画のパスに触れた区間は起点を渡して描き変わった本数を出す(self):
        base = self.commits[0]
        self.commit("Sources/MokumeCore/Sketch/Sketch+Style.swift", "x\n")
        rows = (
            "Sources/MokumeCore/Sketch/Sketch+Style.swift:12\t3f9a1c8d\t120\t1000\t17\t0\t赤い円\n"
            "Sources/MokumeCore/Sketch/Sketch+Style.swift:40\t0badf00d\t7\t1000\t2\t0\t青い線\n"
        )
        count, _, record = self.run_drift(base=base, rows=rows)
        self.assertEqual(count, "2")
        args = self.called.read_text().split()
        self.assertEqual(args[args.index("--drift") + 1], base)
        self.assertIn("--drift-record", args)
        self.assertEqual(len((record / "drifts.tsv").read_text().splitlines()), 2)
        # 起票の本文が区間の比較の URL を作る材料
        self.assertEqual((record / "range.txt").read_text().split()[0], base)

    def test_描いて変わった絵が無ければ_0_を出す(self):
        base = self.commits[0]
        self.commit("Sources/MokumeCore/A.swift", "x\n")
        count, _, record = self.run_drift(base=base, rows="")
        self.assertEqual(count, "0")
        self.assertTrue(self.called.exists(), "触れた区間なのに描いていない")
        self.assertEqual((record / "drifts.tsv").read_text(), "")


class WiringTest(unittest.TestCase):
    """render.yml の名前と path を読み、スクリプトの側と突き合わせる (#2706)。

    3 つの job をまたぐ配線 (門番の出力 → 専用機の env → artifact → 報告の step) は、1 か所の綴りが
    ずれても、各部品の検査 (偽の入力で走らせる) は緑のまま通る。ずれると**起票が黙って起きなくなる**
    (artifact の名前や path が違えば記録が空になり、出力の名前が違えば env が空になる)。
    step が 0 本で走査が空回りして緑になる形も、数を固定して防ぐ。
    """

    @classmethod
    def setUpClass(cls):
        import re

        import render_workflow_test as wf

        cls.re = re
        cls.wf = wf
        cls.top, cls.jobs = wf.split((REPO / ".github" / "workflows" / "render.yml").read_text(encoding="utf-8"))
        cls.drift_sh = DRIFT_SCRIPT.read_text(encoding="utf-8")
        cls.base_sh = BASE_SCRIPT.read_text(encoding="utf-8")
        cls.report_sh = REPORT_SCRIPT.read_text(encoding="utf-8")

    def field(self, step, key):
        m = self.re.search(rf"(?m)^\s+{key}: (\S+)\s*$", step)
        self.assertIsNotNone(m, f"{key}: が無い: {step}")
        return m.group(1)

    def test_記録は_artifact_の名前と_path_を通って報告の_step_に届く(self):
        uploads = [s for s in self.wf.steps(self.jobs["scheduled-drift"]) if "actions/upload-artifact@" in s]
        self.assertEqual(len(uploads), 1, "upload-artifact の step が 1 本でない (走査が空回りしていないか)")
        name = self.field(uploads[0], "name")
        uploaded_path = self.field(uploads[0], "path")
        # (b) 上げる path は、スクリプトが記録を置く先 (DRIFT_RECORD の既定) と同じ
        default = self.re.search(r'RECORD="\$\{DRIFT_RECORD:-([^}]+)\}"', self.drift_sh)
        self.assertIsNotNone(default, "scheduled-drift.sh の RECORD の既定が読めない")
        self.assertEqual(uploaded_path.rstrip("/"), default.group(1).rstrip("/"))
        # (c) 報告の job は同じ名前の artifact を落とし、置いた先を find で読む
        report = self.jobs["scheduled-report"]
        downloads = [s for s in self.wf.steps(report) if "actions/download-artifact@" in s and f"name: {name}" in s]
        self.assertEqual(len(downloads), 1, f"{name} を落とす step が 1 本でない")
        download_path = self.field(downloads[0], "path")
        finds = self.re.findall(r"find (\S+) -name drifts\.tsv", report)
        self.assertEqual(finds, [download_path], "報告の step の find の先が、download の path と違う")
        # 記録のファイル名は、置く側 (scheduled-drift.sh と example-shots.py)・読む側 (報告) で同じ
        for file in ("drifts.tsv", "summary.md"):
            self.assertIn(file, self.report_sh, file)
            self.assertIn(file, self.drift_sh, file)
        self.assertIn("range.txt", self.report_sh)
        self.assertIn("range.txt", self.drift_sh)
        shots = (REPO / "scripts" / "example-shots.py").read_text(encoding="utf-8")
        self.assertIn('"drifts.tsv"', shots)
        self.assertIn('"summary.md"', shots)
        # 報告の step は、その find の結果の dirname を、報告のスクリプトへ渡す
        self.assertIn("scripts/report-example-drift.sh", report)

    def test_起点と本数の出力は_job_と_step_の名前を通ってスクリプトに届く(self):
        turn = self.jobs["scheduled-drift-turn"]
        drift = self.jobs["scheduled-drift"]
        # (d) 門番の outputs は、drift-base.sh を走らせる step (id) の出力で、その key は
        # drift-base.sh が書く key と同じ
        step_id = self.re.search(r"- id: (\w+)\n(?:\s+env:\n(?:\s+\w+: .+\n)+)?\s+run: bash scripts/drift-base\.sh", turn)
        self.assertIsNotNone(step_id, "門番に drift-base.sh を走らせる id 付きの step が無い")
        emitted = set(self.re.findall(r"printf '(\w+)=%s", self.base_sh))
        self.assertEqual(emitted, {"base", "reason"})
        outs = {
            k: f"{sid}.{out}"
            for k, sid, out in self.re.findall(r"(?m)^      (\w+): \$\{\{ steps\.(\w+)\.outputs\.(\w+) \}\}$", turn)
        }
        for key in ("base", "reason"):
            self.assertEqual(outs.get(key), f"{step_id.group(1)}.{key}", f"門番の outputs.{key} の行き先")
        # 専用機の job の env は、門番の出力を読み、スクリプトはその名前の env を読む
        for env, key in (("DRIFT_BASE", "base"), ("DRIFT_BASE_REASON", "reason")):
            self.assertIn(f"{env}: ${{{{ needs.scheduled-drift-turn.outputs.{key} }}}}", drift)
            self.assertIn(f"${{{env}:-", self.drift_sh)
        # 本数: スクリプトが書く key → step の id → job の outputs → 報告の読み方
        self.assertIn("printf 'drift-count=%s", self.drift_sh)
        count_step = self.re.search(r"- id: (\w+)\n(?:\s+env:\n(?:\s+\w+: .+\n)+)?\s+run: bash scripts/scheduled-drift\.sh", drift)
        self.assertIsNotNone(count_step, "scheduled-drift.sh を走らせる id 付きの step が無い")
        self.assertIn(f"drift-count: ${{{{ steps.{count_step.group(1)}.outputs.drift-count }}}}", drift)
        self.assertIn("needs.scheduled-drift.outputs.drift-count", self.jobs["scheduled-report"])


class ReportExampleDriftTest(unittest.TestCase):
    """起票。偽 gh は report_check_failure_test.py と同じ形 (起票・追記・書き換え)。"""

    def setUp(self):
        import report_check_failure_test as shared

        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(shared.FAKE_GH)
        gh.chmod(0o755)
        self.bin_dir = bin_dir
        self.log = self.dir / "gh.log"
        self.body = self.dir / "body.md"
        self.record = self.dir / "record"
        self.record.mkdir()

    def report(self, **env_extra):
        self.log.write_text("")
        env = {
            **os.environ,
            "PATH": f"{self.bin_dir}:{os.environ['PATH']}",
            "FAKE_GH_LOG": str(self.log),
            "FAKE_BODY_OUT": str(self.body),
            "FAKE_EDIT_OUT": str(self.dir / "edited.md"),
            "FAKE_ISSUE_LIST": "[]",
            "GITHUB_REPOSITORY": "mokume-metal/mokume",
            **env_extra,
        }
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        done = sh("/bin/bash", str(REPORT_SCRIPT), str(self.record), cwd=REPO, env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        return self.log.read_text()

    def write_record(self, rows):
        (self.record / "summary.md").write_text(
            "## 例の絵の前後の比較\n\n13 本を a と比べて、**2 本の画素が変わっている。**\n\n"
            "| 説明文 | snippet= | 違う画素 | 最大の差 | 一文の説明 |\n| --- | --- | --- | --- | --- |\n"
            "| `Sources/Sketch+Style.swift:12` | `3f9a1c8d` | 120 / 1000 | 17 | 赤い円 |\n"
        )
        (self.record / "range.txt").write_text("a" * 40 + " " + "b" * 40 + "\n")
        (self.record / "drifts.tsv").write_text(rows)

    def test_変わった絵があれば固定タイトルで起票し本文に表と区間の比較を載せる(self):
        self.write_record("Sources/Sketch+Style.swift:12\t3f9a1c8d\t120\t1000\t17\t0\t赤い円\n")
        log = self.report()
        self.assertIn("issue create", log)
        self.assertIn(TITLE, log)
        body = self.body.read_text()
        self.assertIn("`3f9a1c8d`", body)  # snippet=
        self.assertIn("120 / 1000", body)  # 違う画素
        self.assertIn("Sources/Sketch+Style.swift:12", body)  # ファイル
        self.assertIn(f"compare/{'a' * 40}...{'b' * 40}", body)  # 区間
        self.assertIn("解消の判定", body)
        self.assertIn("解消したらこの Issue を閉じる", body)

    def test_変わった絵が無ければ起票しない(self):
        self.write_record("")
        log = self.report()
        self.assertNotIn("issue", log)
        self.assertFalse(self.body.exists())

    def test_記録が無くても名乗られた本数があれば起票する(self):
        # artifact を落とせなかった回。ここで黙ると、名指しされた絵が誰にも届かない
        (self.record / "summary.md").unlink(missing_ok=True)
        log = self.report(DRIFT_COUNT="3")
        self.assertIn("issue create", log)
        self.assertIn("3 本", self.body.read_text())

    def test_記録が無く本数も無ければ起票しない(self):
        log = self.report()
        self.assertNotIn("issue", log)


if __name__ == "__main__":
    unittest.main()
