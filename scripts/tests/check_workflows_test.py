#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-workflows.sh の道具の取得の検査 (#1195)。

守りたいのは 3 つ (Issue #1195 の完了条件):
  1. 一時的な失敗は有限回取り直す — 1 回きりだと GitHub 側の 504 で段ごと落ち、merge queue
     から PR が外される (#1190 / #1192 が踏んだ)
  2. 取り直しても取れなければ赤で落ち、途中の配布物を残さない。照合も変わらず効く
  3. 照合の失敗は取り直さない — 改竄を取り直しで押し通さない

GitHub へは行かない。手元に偽のサーバを立て、スクリプトを source して fetch_tool だけを
その URL に向けて呼ぶ。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import hashlib
import http.server
import io
import subprocess
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# 応答を返さずに接続を切る (curl は 52 で落ちる)。--retry 単独では取り直されない形
DROP = 0
# 200 と本来の長さを名乗り、本文を半分だけ書いて切る (curl は 18 で落ち、書きかけが残る)
PARTIAL = 1
SCRIPT = REPO / "scripts" / "check-workflows.sh"


def tarball(member: str, body: bytes) -> bytes:
    """実行可能なファイル 1 つだけを含む tar.gz。"""
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as archive:
        info = tarfile.TarInfo(member)
        info.size = len(body)
        info.mode = 0o755
        archive.addfile(info, io.BytesIO(body))
    return out.getvalue()


class FetchToolTest(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="check-workflows-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.work)])
        self.payload = tarball("actionlint", b"#!/bin/sh\necho fake\n")
        # 何回目の要求に何を返すか。尽きたら最後の 1 つを返し続ける。
        # DROP は応答を返さずに接続を切り、PARTIAL は本文の途中で切る
        self.answers: list[int] = []
        self.requests = 0

    def serve(self, *answers: int) -> str:
        test = self
        test.answers = list(answers)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                index = min(test.requests, len(test.answers) - 1)
                test.requests += 1
                status = test.answers[index]
                if status == DROP:
                    self.close_connection = True
                    return
                if status == PARTIAL:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(test.payload)))
                    self.end_headers()
                    self.wfile.write(test.payload[: len(test.payload) // 2])
                    self.close_connection = True
                    return
                self.send_response(status)
                body = test.payload if status == 200 else b"gateway timeout"
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            # 要求のログは捨てる。既定では stderr へ出て、検査の出力に混ざる
            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}/actionlint.tar.gz"

    def fetch(self, url: str, sha256: str | None = None) -> subprocess.CompletedProcess:
        expected = sha256 or hashlib.sha256(self.payload).hexdigest()
        tools = self.work / "tools"
        # source は関数を定義するだけで止まる。TOOLS_DIR は source の後に差し替える
        command = (
            f'source "{SCRIPT}"; TOOLS_DIR="{tools}"; '
            f'fetch_tool "$1" "$2" actionlint 0 "{tools}/actionlint-pinned"'
        )
        return subprocess.run(
            ["/bin/bash", "-c", command, "fetch", url, expected],
            cwd=REPO, capture_output=True, text=True, timeout=120,
        )

    @property
    def dest(self) -> Path:
        return self.work / "tools" / "actionlint-pinned"

    @property
    def leftover(self) -> Path:
        return self.work / "tools" / "actionlint-pinned.tar.gz"

    def test_1_回目だけ_504_なら取り直して取れる(self):
        result = self.fetch(self.serve(504, 200))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.dest.is_file())
        self.assertEqual(self.dest.stat().st_mode & 0o111, 0o111)
        self.assertEqual(self.requests, 2)
        self.assertFalse(self.leftover.exists())

    def test_1_回目に接続が切れても取り直して取れる(self):
        result = self.fetch(self.serve(DROP, 200))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.dest.is_file())
        self.assertEqual(self.requests, 2)

    def test_ずっと_504_なら有限回で諦め配布物を残さない(self):
        result = self.fetch(self.serve(504))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("取得できなかった", result.stderr)
        # 最初の 1 回 + 取り直し 3 回
        self.assertEqual(self.requests, 4)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.leftover.exists())

    def test_ずっと途中で切れるなら書きかけを残さない(self):
        # 書きかけが残ると、次に打った人の手元で壊れた配布物が置き場に居続ける
        result = self.fetch(self.serve(PARTIAL))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("取得できなかった", result.stderr)
        self.assertEqual(self.requests, 4)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.leftover.exists())

    def test_照合が合わなければ取り直さずに落ちる(self):
        result = self.fetch(self.serve(200), sha256="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("チェックサムが一致しない", result.stderr)
        self.assertEqual(self.requests, 1)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.leftover.exists())

    def test_source_しても本体は走らない(self):
        # 本体が走ると道具の解決と actionlint の実行に進み、echo の前に exec で置き換わる
        result = subprocess.run(
            ["/bin/bash", "-c", f'source "{SCRIPT}"; echo sourced'],
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "sourced\n")


if __name__ == "__main__":
    unittest.main()
