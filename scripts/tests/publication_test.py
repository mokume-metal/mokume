#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-publication.py の検査 (#483)。

この道具が塞ぐのは「ビルドは緑のまま、公開だけが古い」である。固定するのは 3 系統:

- **古い公開を赤くする** — 猶予を越えて追いついていない公開は必ず赤い。逆に、公開が
  走っている最中の数分は緑のまま (毎日鳴る狼にしないため)。境界の両側を見る
- **印が読めない状態を緑にしない** — 引けない・形が違う・履歴に無い、のどれも赤
- **ドメインの設定のずれを赤くする** — GitHub 側は写しなので、意図と違えば赤い

印を書く側と読む側が同じ形式を持っていることも往復で見る。片方だけ直すと、公開の
追随は「いつも赤い」か「いつも緑」のどちらかに固定される。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import http.server
import functools
import importlib.util
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-publication.py"

_spec = importlib.util.spec_from_file_location("check_publication", SCRIPT)
publication = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(publication)

NOW = 1_700_000_000
OLD = "a" * 40
NEW = "b" * 40


def behind(*ages_in_minutes):
    """`published..HEAD` の見立て。新しい順に、いま基準で何分前かで書く。"""
    return [(f"{index}" * 40, NOW - minutes * 60) for index, minutes in enumerate(ages_in_minutes)]


class FreshnessTest(unittest.TestCase):
    def test_同じコミットを配っていれば緑(self):
        self.assertEqual(publication.freshness_problems(OLD, OLD, [], NOW), [])

    def test_公開が走っている最中は緑(self):
        # 猶予 (45 分) の内側にしか未公開のコミットが無い = いま公開が走っている
        problems = publication.freshness_problems(OLD, NEW, behind(3, 20), NOW)
        self.assertEqual(problems, [])

    def test_猶予を越えた未公開のコミットがあれば赤(self):
        problems = publication.freshness_problems(OLD, NEW, behind(5, 90), NOW)
        self.assertEqual(len(problems), 1)
        self.assertIn("2 コミットぶん古い", problems[0])
        # いちばん古い未公開のコミットを名指しする (どこから止まっているかが分かる)
        self.assertIn("1" * 12, problems[0])
        self.assertIn("90 分前", problems[0])

    def test_猶予ちょうどは緑で_その次の秒から赤(self):
        self.assertEqual(publication.freshness_problems(OLD, NEW, behind(45), NOW), [])
        self.assertNotEqual(
            publication.freshness_problems(OLD, NEW, behind(45), NOW + 1),
            [],
        )

    def test_履歴に無い印は赤(self):
        problems = publication.freshness_problems(OLD, NEW, None, NOW)
        self.assertEqual(len(problems), 1)
        self.assertIn("手元の履歴に無い", problems[0])

    def test_公開のほうが新しければ緑(self):
        # 手元のチェックアウトが古いだけで、追随の問題ではない
        self.assertEqual(publication.freshness_problems(NEW, OLD, [], NOW), [])


class DomainTest(unittest.TestCase):
    def test_意図どおりなら緑(self):
        settings = {"cname": publication.DOMAIN, "https_enforced": True}
        self.assertEqual(publication.domain_problems(settings), [])

    def test_Pages_が無効なら赤(self):
        self.assertEqual(publication.domain_problems(None), ["Pages が有効になっていない"])

    def test_ドメインが未設定なら赤(self):
        problems = publication.domain_problems({"cname": None, "https_enforced": True})
        self.assertEqual(len(problems), 1)
        self.assertIn(publication.DOMAIN, problems[0])

    def test_HTTPS_が要求されていなければ赤(self):
        settings = {"cname": publication.DOMAIN, "https_enforced": False}
        self.assertEqual(publication.domain_problems(settings), ["Enforce HTTPS が入っていない"])


class StampTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.site = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_書いた印はそのまま読める(self):
        publication.write_stamp(self.site, OLD)
        self.assertEqual(publication.read_stamp(str(self.site)), (OLD, None))

    def test_SHA_でないものは書かせない(self):
        with self.assertRaises(SystemExit):
            publication.write_stamp(self.site, "main")

    def test_印が無ければ理由を返す(self):
        found, reason = publication.read_stamp(str(self.site))
        self.assertIsNone(found)
        self.assertIn(publication.STAMP_NAME, reason)

    def test_形の違う印は読まない(self):
        (self.site / publication.STAMP_NAME).write_text("<html>404</html>\n", encoding="utf-8")
        found, reason = publication.read_stamp(str(self.site))
        self.assertIsNone(found)
        self.assertIn("40 桁の SHA ではない", reason)

    def test_URL_でも同じ形で読める(self):
        publication.write_stamp(self.site, NEW)

        class Quiet(http.server.SimpleHTTPRequestHandler):
            # 要求のログは捨てる。既定では stderr へ出て、検査の出力に混ざる
            def log_message(self, *args):
                pass

        handler = functools.partial(Quiet, directory=str(self.site))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        base = f"http://127.0.0.1:{server.server_address[1]}"
        self.assertEqual(publication.read_stamp(base), (NEW, None))

        (self.site / publication.STAMP_NAME).unlink()
        found, reason = publication.read_stamp(base)
        self.assertIsNone(found)
        self.assertIn("404", reason)


class CommandTest(unittest.TestCase):
    """CLI としての往復。判定の単体ではなく、口が繋がっていることを見る。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.site = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def run_script(self, *arguments):
        return subprocess.run(
            ["python3", str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            cwd=REPO,
        )

    def head(self):
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True, cwd=REPO
        ).stdout.strip()

    def test_書いた印を引くと緑になる(self):
        written = self.run_script("--write-stamp", str(self.site), "--commit", self.head())
        self.assertEqual(written.returncode, 0, written.stderr)

        result = self.run_script("--site", str(self.site), "--skip-domain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("追随している", result.stdout)

    def test_印が無ければ赤になる(self):
        result = self.run_script("--site", str(self.site), "--skip-domain")
        self.assertEqual(result.returncode, 1)
        self.assertIn(publication.STAMP_NAME, result.stderr)
        # 設定は見ていないので、設定の手順は出さない (済んだ作業を毎回勧めない)
        self.assertNotIn("Cloudflare", result.stderr)


if __name__ == "__main__":
    unittest.main()
