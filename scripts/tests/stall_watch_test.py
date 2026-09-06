#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/stall-watch.sh と scripts/stall-act.sh の検査 (#961)。

固定したいのは七つ。

1. **pr-title へ rerun を打たない。** pull_request の rerun は元のイベントを再生するので、
   古いタイトルで判定され、その失敗が最新の結果になって**打つ前より悪くなる** (#699)。
   run 単位で `--failed` を打つと pr-title は同じ run の中に居るので巻き添えになる
2. **同じ run の他の失敗ジョブには打つ。** 1 を守るために全部を飛ばしてしまうと、
   古い失敗 check が判定を固定したまま (#259 / #513) 誰も直さなくなる
3. **凍結されたペイロードの可変欄を読むジョブが、除外リストに載っている。** いまは
   pr-title 1 本だが、同じ形のジョブが増えたときに人が気付く経路が無い (#801 と同じ形)
4. **BLOCKED の 2 つの意味を分ける。** 承認待ちの PR に auto-merge を掛け直すのは
   無害だが、承認待ちを「詰まっている」と名乗ると本物の詰まりが埋もれる
5. **判定は何も打たない。** 手元で様子を見るために打っただけで auto-merge が掛かると、
   判定と対処を分けた意味が消える
6. **Draft は見ない。** 作業中の PR を Draft にしておくのが opt-out である
7. **猶予の中の名乗りでは赤くしない。** 15 分ごとに通知が飛ぶと「毎回出る注意は意味を
   失う」(#642) を踏む

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、
検査は判定そのものを踏む (応答を素通しにすると、絞り込みの誤りが素通りする)。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WATCH = REPO / "scripts" / "stall-watch.sh"
ACT = REPO / "scripts" / "stall-act.sh"
CI_WORKFLOW = REPO / ".github" / "workflows" / "ci.yml"

# --jq の値を取り出して本物の jq を当てる。応答は $PR_DIR の中の JSON から読む
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

emit() { # $1=JSON ファイル
  [ -f "$1" ] || { printf '%s' ""; return 0; }
  if [ -n "$filter" ]; then jq -r "$filter" < "$1"; else cat "$1"; fi
}

if [ "$1 $2" = "pr list" ]; then emit "$PR_DIR/list.json"; exit 0; fi

if [ "$1 $2" = "pr view" ]; then emit "$PR_DIR/$3.json"; exit 0; fi

if [ "$1 $2" = "pr merge" ]; then
  [ -z "${MERGE_FAILS:-}" ] || { echo "gh: cannot enable auto-merge" >&2; exit 1; }
  exit 0
fi

if [ "$1 $2" = "run rerun" ]; then exit 0; fi

if [ "$1 $2" = "api graphql" ]; then
  printf '%s\\n' "${IN_QUEUE:-false}"; exit 0
fi

# **URL は $2 から取る。** "$*" には --jq の値 (複数行) まで混ざるので、
# そこから切り出すと 2 行目以降が素通りして経路名が壊れる
url=${2:-}

case "$url" in
  */check-runs)
    sha=${url%/check-runs}; sha=${sha##*/}
    emit "$PR_DIR/${sha#sha-}.checkruns.json"; exit 0 ;;
  *"/pulls?state=open"*)
    emit "$PR_DIR/pulls.json"; exit 0 ;;
  */files)
    n=${url%/files}; n=${n##*/}
    emit "$PR_DIR/$n.files.json"; exit 0 ;;
esac

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""


def ago(minutes):
    """いま から minutes 分前の ISO8601。"""
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def check(name, result, at=None):
    return {"name": name, "conclusion": result, "completedAt": at or ago(30)}


class StallWatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        bin_dir = root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)

        self.pr_dir = root / "pr"
        self.pr_dir.mkdir()
        self.calls = root / "gh-calls.txt"
        self.calls.write_text("", encoding="utf-8")
        self.bin_dir = bin_dir

        # 順番の判定 (ahead_drawing_pr) が読む一覧。既定は自分 1 本だけ
        self.write("pulls.json", [])

    def write(self, name, payload):
        (self.pr_dir / name).write_text(json.dumps(payload), encoding="utf-8")

    def add_pr(
        self,
        number,
        *,
        draft=False,
        auto=True,
        state="CLEAN",
        checks=(),
        approved=False,
        updated=None,
        files=(),
    ):
        listing = []
        path = self.pr_dir / "list.json"
        if path.exists():
            listing = json.loads(path.read_text(encoding="utf-8"))
        listing.append({"number": number, "isDraft": draft})
        self.write("list.json", listing)

        self.write(
            f"{number}.json",
            {
                "isDraft": draft,
                "autoMergeRequest": {"enabledAt": ago(60)} if auto else None,
                "mergeStateStatus": state,
                "statusCheckRollup": list(checks),
                "latestReviews": [{"state": "APPROVED"}] if approved else [],
                "updatedAt": updated or ago(30),
                "headRefOid": f"sha-{number}",
            },
        )
        self.write(f"{number}.files.json", [{"filename": f} for f in files])

    def env(self, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env["GH_CALLS"] = str(self.calls)
        env["PR_DIR"] = str(self.pr_dir)
        # 手元で打ったときの既定を再現する (Actions の変数が残っていると分岐が変わる)
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL", "GITHUB_EVENT_NAME", "GH_TOKEN"):
            env.pop(key, None)
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def watch(self, **extra):
        proc = subprocess.run(
            ["/bin/bash", str(WATCH)],
            capture_output=True,
            text=True,
            env=self.env(**extra),
        )
        return proc

    def act(self, lines, **extra):
        log = Path(self.tmp.name) / "stall.log"
        log.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
        return subprocess.run(
            ["/bin/bash", str(ACT), str(log)],
            capture_output=True,
            text=True,
            env=self.env(**extra),
        )

    def gh_log(self):
        return self.calls.read_text(encoding="utf-8")

    def classify(self, number, proc):
        for line in proc.stdout.splitlines():
            parts = line.split(maxsplit=3)
            if parts and parts[0] == str(number):
                return parts[1], parts[2]
        return None, None

    # --- 判定 ---------------------------------------------------------------

    def test_Draft_の_PR_は見ない(self):
        self.add_pr(1, draft=True, auto=False, state="BLOCKED")
        proc = self.watch()
        self.assertEqual(proc.stdout.strip(), "", proc.stdout)

    def test_auto_merge_が外れた_PR_は打つに分類される(self):
        self.add_pr(2, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")])
        kind, action = self.classify(2, self.watch())
        self.assertEqual((kind, action), ("auto-merge-dropped", "act"))

    def test_承認が要る未承認の_PR_は黙るに分類される(self):
        self.add_pr(
            3,
            auto=False,
            state="BLOCKED",
            checks=[check("ci-gate", "SUCCESS")],
            files=[".github/workflows/ci.yml"],
        )
        kind, action = self.classify(3, self.watch())
        self.assertEqual((kind, action), ("awaiting-approval", "quiet"))

    def test_承認済みなら_auto_merge_が外れたと読む(self):
        self.add_pr(
            4,
            auto=False,
            state="BLOCKED",
            approved=True,
            checks=[check("ci-gate", "SUCCESS")],
            files=[".github/workflows/ci.yml"],
        )
        kind, action = self.classify(4, self.watch())
        self.assertEqual((kind, action), ("auto-merge-dropped", "act"))

    def test_queue_に居る_PR_は黙る(self):
        self.add_pr(5, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")])
        kind, action = self.classify(5, self.watch(IN_QUEUE="true"))
        self.assertEqual((kind, action), ("in-queue", "quiet"))

    def test_衝突して_check_が_1_本も付かない_PR_を名乗る(self):
        self.add_pr(6, auto=True, state="UNKNOWN", checks=[])
        kind, action = self.classify(6, self.watch())
        self.assertEqual((kind, action), ("conflict", "name"))

    def test_手元の報告だけが付いた_PR_も_check_0_本と数える(self):
        # AGENTS.md 行 1 の「local-render のような手元の commit status を除く」
        self.add_pr(
            7, auto=True, state="UNKNOWN", checks=[check("local-render", "SUCCESS")]
        )
        kind, _ = self.classify(7, self.watch())
        self.assertEqual(kind, "conflict")

    def test_local_render_が失敗した描画_PR_を名乗る(self):
        self.add_pr(
            8,
            auto=True,
            state="BLOCKED",
            checks=[check("local-render", "FAILURE"), check("ci-gate", "SUCCESS")],
            files=["Sources/MokumeCore/Drawing/Canvas.swift"],
        )
        self.write("pulls.json", [{"number": 8, "draft": False}])
        kind, action = self.classify(8, self.watch())
        self.assertEqual((kind, action), ("ejected", "name"))

    def test_古い失敗_check_が残る_PR_は打つに分類される(self):
        self.add_pr(
            9,
            auto=True,
            state="BLOCKED",
            checks=[
                check("ci-gate", "FAILURE", ago(90)),
                check("ci-gate", "SUCCESS", ago(10)),
            ],
        )
        kind, action = self.classify(9, self.watch())
        self.assertEqual((kind, action), ("stale-checks", "act"))

    def test_pr_title_が落ちた_PR_は名乗るに分類される(self):
        # **stale-checks より先に判定されること。** 後ろだと rerun を打ってしまう
        self.add_pr(
            10,
            auto=True,
            state="BLOCKED",
            checks=[
                check("pr-title", "FAILURE", ago(10)),
                check("ci-gate", "FAILURE", ago(90)),
                check("ci-gate", "SUCCESS", ago(5)),
            ],
        )
        kind, action = self.classify(10, self.watch())
        self.assertEqual((kind, action), ("bad-title", "name"))

    def test_判定は何も打たない(self):
        self.add_pr(11, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")])
        self.watch()
        log = self.gh_log()
        self.assertNotIn("pr merge", log)
        self.assertNotIn("run rerun", log)

    def test_猶予の中の名乗りでは_0_で終える(self):
        self.add_pr(12, auto=True, state="UNKNOWN", checks=[], updated=ago(5))
        proc = self.watch(STALL_MINUTES=60)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_猶予を超えた名乗りでは_1_で終える(self):
        self.add_pr(13, auto=True, state="UNKNOWN", checks=[], updated=ago(120))
        proc = self.watch(STALL_MINUTES=60)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_打つ行だけでは赤くしない(self):
        self.add_pr(14, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")])
        proc = self.watch(STALL_MINUTES=1)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    # --- 対処 ---------------------------------------------------------------

    def test_pr_title_の失敗ジョブに_rerun_を打たない(self):
        self.add_pr(20)
        self.write(
            "20.checkruns.json",
            {
                "check_runs": [
                    {"name": "pr-title", "conclusion": "failure", "id": 111},
                    {"name": "ci-check", "conclusion": "failure", "id": 222},
                ]
            },
        )
        proc = self.act(["20 stale-checks act 5 古い失敗 check"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertNotIn("--job 111", log, "pr-title へ rerun を打っている")
        self.assertIn("--job 222", log, "同じ run の他の失敗ジョブへ打っていない")

    def test_名乗る行には何も打たない(self):
        proc = self.act(["21 conflict name 90 main と衝突している"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertNotIn("pr merge", log)
        self.assertNotIn("run rerun", log)

    def test_auto_merge_を掛け直す(self):
        proc = self.act(["22 auto-merge-dropped act 0 外れている"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("pr merge 22", self.gh_log())

    def test_掛け直しに失敗したら_1_で終える(self):
        proc = self.act(["23 auto-merge-dropped act 0 外れている"], MERGE_FAILS="1")
        self.assertEqual(proc.returncode, 1)

    def test_入力ファイルが無ければ_66_で終える(self):
        proc = subprocess.run(
            ["/bin/bash", str(ACT), str(Path(self.tmp.name) / "無い.log")],
            capture_output=True,
            text=True,
            env=self.env(),
        )
        self.assertEqual(proc.returncode, 66)


class RerunExclusionTest(unittest.TestCase):
    """凍結ペイロードの可変欄を読むジョブが、除外リストに載っているか (#801 と同じ形)。

    pull_request の rerun は元のイベントを再生するので、title / body / labels を
    ペイロードから受け取るジョブは古い値で判定される。番号や sha は run の中で
    変わらないので、それだけを受け取るジョブは rerun して安全である。
    """

    MUTABLE = ("title", "body", "labels")

    def excluded_jobs(self):
        text = ACT.read_text(encoding="utf-8")
        found = re.search(r'RERUN_EXCLUDED=\$\{RERUN_EXCLUDED:-"([^"]*)"\}', text)
        self.assertIsNotNone(found, "stall-act.sh の除外リストを読めない")
        return set(found.group(1).split())

    def jobs_reading_mutable_payload(self):
        """ci.yml を走査し、可変欄を式に含むジョブの名前を返す。"""
        jobs = set()
        current = None
        in_jobs = False
        for line in CI_WORKFLOW.read_text(encoding="utf-8").splitlines():
            if re.match(r"^jobs:\s*$", line):
                in_jobs = True
                continue
            if in_jobs and re.match(r"^\S", line):
                in_jobs = False
            if not in_jobs:
                continue
            named = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if named:
                current = named.group(1)
                continue
            if current and any(
                f"github.event.pull_request.{field}" in line for field in self.MUTABLE
            ):
                jobs.add(current)
        return jobs

    def test_可変欄を読むジョブが除外リストに載っている(self):
        reading = self.jobs_reading_mutable_payload()
        self.assertTrue(reading, "ci.yml から可変欄を読むジョブを 1 つも拾えていない")
        missing = reading - self.excluded_jobs()
        self.assertEqual(
            missing,
            set(),
            f"凍結されたペイロードを読むのに rerun の除外に載っていない: {sorted(missing)}"
            " — stall-act.sh の RERUN_EXCLUDED へ足す (#699)",
        )


if __name__ == "__main__":
    unittest.main()
