#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""外に置いた資産の死活の赤を発信する検査 (#1295)。

`scripts/report-dead-assets.sh` が持つのは**固定タイトルと本文**だけで、起票の手続きは
`report-check-failure.sh` が 1 つ持つ (そちらの 6 点は `report_check_failure_test.py` が
留める)。ここで固定するのは、この検査に固有の 6 つ:

  1. 固定タイトルが `fix(` で始まる — triage.sh は接頭辞から型を推定するので、ここが
     崩れると型の無い Issue になる。動いていた絵が読めなくなった事象なので Bug である
     (AGENTS.md の「迷ったら Bug > Design > Docs > Task」)
  2. 本文に解消の判定が載る — トリアージ済みの印は「どの検査で判定するか」の明記を要件に
     している (ADR-0002 決定 1)。対処法だけ書いて判定基準の無い起票は、要件を満たさない
     まま印だけ付けることになる
  3. 本文に「解消したら閉じる」が載る — この機構は**自動では閉じない** (緑は「直った」を
     意味しない。指し先を消しても緑になりうる)。代わりに、open な間は重複起票を抑えることを
     動く人が読む場所へ書く。ここが落ちると、閉じ忘れが次の事象を黙らせる (#1295 の完了条件 3)
  4. 引けなかった指し先が本文に載る — 出所 (ファイルと行) を含む死活の出力がそのまま
     撮り直しの作業指示になる
  5. 共通部品を通っている — 同名の Issue が open なら二重に立てない。ここが写しになると、
     片方だけが直ったときに黙って壊れる (ADR-0008 決定 6)

6. リリースノートの絵の 404 が起票の本文まで届く (#2268) — 検査と発信を本物のまま通す dry-run。
   実物の Release に 404 を混ぜずに、日次の publication が起票するところまでを確かめる

偽 gh は PATH の先頭に置いた同型のスタブ (`ruleset_drift_test.py` と同じ形)。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import http.server
import json
import os
import socketserver
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-dead-assets.sh"

# report-dead-assets.sh の TITLE と同じ文字列。ここがずれたら重複判定が壊れる
TITLE = "fix(docs): 外に置いた視覚証跡が引けない"

# check-external-assets.py が落ちたときの出力の形 (指し先 — 理由 / 出所)
ASSETS_LOG = """外部資産の指し先: 178 本 (186 箇所から)
外に置いた資産が引けない:
  https://i.gyazo.com/021262387681ab64202dd35e05b95479.png — HTTP 404
    Documentation/mokume.docc/Rotate.md:12
  https://gyazo.com/323d13551c98f40083a134d04aa209c8 — HTTP 404
    Sources/MokumeCore/Shapes.swift:88
"""

FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
query=
prev=
for a in "$@"; do
  [ "$prev" = "--jq" ] && query=$a
  prev=$a
done
case "$1 $2" in
  "issue list") json=$FAKE_ISSUE_LIST ;;
  "issue create")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_BODY_OUT"
      prev=$a
    done
    echo "https://github.com/mokume-metal/mokume/issues/4242"
    exit 0 ;;
  "issue view")
    case "$*" in
      *issueType*) json='{"issueType":null}' ;;
      *) json='{"labels":[]}' ;;
    esac ;;
  "issue edit") exit 0 ;;
  "api repos/{owner}/{repo}/releases"*) cat "$FAKE_RELEASES"; exit 0 ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""


class ReportDeadAssetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

        self.bin_dir = self.dir / "bin"
        self.bin_dir.mkdir()
        gh = self.bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.body = self.dir / "body.md"

    def report(self, assets=ASSETS_LOG, issue_list="[]"):
        assets_file = self.dir / "assets.log"
        assets_file.write_text(assets)
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_ISSUE_LIST": issue_list,
                "FAKE_BODY_OUT": str(self.body),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )
        # 実行の残骸 (run URL) が本文に混じらないよう、Actions の変数は落とす
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(assets_file)],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )

    def gh_log(self):
        return self.log.read_text()

    def test_死活が落ちたら起票する(self):
        r = self.report()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())

    def test_固定タイトルから型が付く(self):
        self.report()
        log = self.gh_log()
        self.assertIn(f"--title {TITLE}", log)
        self.assertIn("--type Bug", log)

    def test_本文に解消の判定基準が載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("## 解消の判定", body)
        self.assertIn("check-external-assets.py", body)

    def test_本文が解消したら閉じることを言う(self):
        # 自動では閉じないので、閉じるのは人である。open な間は重複起票を抑えることを
        # 本文が言わないと、閉じ忘れが次の事象を黙らせる
        self.report()
        body = self.body.read_text()
        self.assertIn("解消したらこの Issue を閉じる", body)
        self.assertIn("重複起票を抑える", body)

    def test_本文に引けなかった指し先と出所が載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("i.gyazo.com/021262387681ab64202dd35e05b95479.png", body)
        self.assertIn("Documentation/mokume.docc/Rotate.md:12", body)

    def test_撮り直しの手順を指す(self):
        self.report()
        self.assertIn("visual-evidence", self.body.read_text())

    def test_全滅のときの行き先を書く(self):
        """置き場ごと止まっているときに撮り直させない (#1333)。

        撮り直しは上げ先を要るので、置き場が落ちている間は通らない。しかも配信が止まって
        いるだけなら絵は消えていないので、撮り直して URL を差し替えると**生きている指し先を
        捨てる**ことになる (#1331)。
        """
        self.report()
        self.assertIn("全滅しているホストがあるなら撮り直さない", self.body.read_text())

    def test_同じ_Issue_が_open_なら二重に立てない(self):
        r = self.report(issue_list=f'[{{"number":42,"title":"{TITLE}"}}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue create", self.gh_log())
        self.assertIn("#42", r.stdout)

    def test_死活検査の出力ファイルが無ければ落ちる(self):
        env = dict(os.environ)
        env.update({"PATH": f"{self.bin_dir}:{env['PATH']}", "FAKE_GH_LOG": str(self.log)})
        r = subprocess.run(
            ["/bin/bash", str(SCRIPT), str(self.dir / "missing.log")],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("死活検査の出力ファイルが無い", r.stderr)

    def test_リリースノートの絵の_404_が起票の本文まで届く(self):
        """#2268 の完了条件: 404 を 1 本混ぜたリリースノートで起票される。

        検査 (check-external-assets.py) と発信 (report-dead-assets.sh) は本物で、差し替えるのは
        Release を返す gh と、引かれる先 (手元の HTTP サーバ。dead.png だけ 404) だけ。
        ワークフローと同じく検査の出力 (標準出力と標準エラー) を 1 本のログにして発信へ渡す。
        """

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(handler):
                handler.send_response(404 if handler.path.endswith("dead.png") else 200)
                handler.send_header("Content-Length", "2")
                handler.end_headers()
                handler.wfile.write(b"ok")

            def log_message(handler, *_):
                pass

        # HTTPServer は bind の後に名前を引き、CI の macOS で約 35 秒止まる (#1714)
        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_address[1]}"

        # 説明文の側に 1 本 (0 本だと検査が成立しない)。ノートの側は生きた 1 本と死んだ 1 本。
        # 下書きの Release は数えない (そこにある 404 は起票に出ない)
        work = self.dir / "work"
        work.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=work, check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ。継がせない (#344)
        subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=work, check=True)
        (work / "guide.md").write_text(f"![説明文の絵]({base}/ok.png)\n", encoding="utf-8")
        subprocess.run(["git", "add", "guide.md"], cwd=work, check=True)
        releases = self.dir / "releases.json"
        releases.write_text(
            json.dumps(
                [
                    {
                        "tag_name": "v9.9.9",
                        "draft": False,
                        "body": "## 修正\n\n- 直した\n\n## この版の絵\n\n"
                        "### [#77 fix: 絵](https://github.com/example/repo/pull/77)\n\n"
                        f"![生きている]({base}/alive.png)\n![死んでいる]({base}/dead.png)\n",
                    },
                    {
                        "tag_name": "v9.9.8",
                        "draft": True,
                        "body": f"## この版の絵\n\n### #1\n\n![下書き]({base}/draft-dead.png)\n",
                    },
                ]
            ),
            encoding="utf-8",
        )
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_RELEASES": str(releases),
                "no_proxy": "127.0.0.1",
            }
        )
        check = subprocess.run(
            ["python3", str(REPO / "scripts" / "check-external-assets.py"), "--root", str(work)],
            capture_output=True,
            text=True,
            env=env,
            cwd=work,
        )
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        log = check.stdout + check.stderr
        self.assertIn("直近 1 版のうち 1 版に 2 本", log)
        self.assertIn(f"{base}/dead.png", log)
        self.assertIn("Release v9.9.9 (#77)", log)
        self.assertNotIn("alive.png", log.split("引けなかった指し先と出所")[-1])
        self.assertNotIn("draft-dead.png", log)

        r = self.report(assets=log)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())
        body = self.body.read_text()
        self.assertIn(f"{base}/dead.png", body)
        self.assertIn("Release v9.9.9 (#77)", body)
        self.assertIn("gh release edit", body)


if __name__ == "__main__":
    unittest.main()
