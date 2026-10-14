#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-workflows.sh の道具の取得の検査 (#1195)。

守りたいのは 3 つ (Issue #1195 の完了条件):
  1. 一時的な失敗は有限回取り直す — 1 回きりだと GitHub 側の 504 で段ごと落ち、merge queue
     から PR が外される (#1190 / #1192 が踏んだ)
  2. 取り直しても取れなければ赤で落ち、途中の配布物を残さない。照合も変わらず効く
  3. 照合の失敗は取り直さない — 改竄を取り直しで押し通さない

あわせて本体の経路 (道具の解決 → actionlint の実行) と、配布物の選び方 (機械の種類ごと) を
`/bin/bash` で起こして見る (#2612。この段は CI では ubuntu で走るので、3.2 での動きはここが持つ)。

GitHub へは行かない。手元に偽のサーバを立て、スクリプトを source して fetch_tool だけを
その URL に向けて呼ぶ。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import hashlib
import http.server
import io
import os
import re
import socketserver
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

        # 名前を引かないサーバで立てる。http.server の HTTPServer は bind の後に getfqdn で
        # 名前を引き、CI の macOS のランナーではそこで約 35 秒止まる (#1714)
        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
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


def pinned_version(name: str) -> str:
    """スクリプトが固定している版 (ACTIONLINT_VERSION など)。写しを持たずに本体から読む。"""
    m = re.search(rf'^{name}="([^"]+)"$', SCRIPT.read_text(encoding="utf-8"), re.M)
    assert m, name
    return m.group(1)


class MainPathTest(unittest.TestCase):
    """本体の経路 (道具の解決 → actionlint の実行) を `/bin/bash` で起こす (#2612)。

    この段は CI では ubuntu の ci-static で走るので、手元とエージェントの `/bin/bash` (3.2) と
    BSD の道具で動くことは、macOS に残るここが持つ (#702)。道具は代役で、取りには行かない。
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="check-workflows-main-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.root = self.tmp / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", "."], cwd=self.root, check=True)
        subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=self.root, check=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.calls = self.tmp / "calls"

    def stub(self, path: Path, version_flag: str, version_line: str):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "#!/bin/sh\n"
            f'if [ "$1" = "{version_flag}" ]; then echo "{version_line}"; exit 0; fi\n'
            f'printf \'%s\\n\' "$@" > "{self.calls}"\n'
            'exit "${FAKE_RC:-0}"\n'
        )
        path.chmod(0o755)

    def run_main(self, *args, **env):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args], cwd=self.root,
            env={**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin", **env},
            capture_output=True, text=True, timeout=60,
        )

    def test_PATH_の道具がピンと同版ならそれで_actionlint_を走らせる(self):
        shellcheck = self.bin / "shellcheck"
        self.stub(shellcheck, "--version", f"version: {pinned_version('SHELLCHECK_VERSION')}")
        self.stub(self.bin / "actionlint", "-version", pinned_version("ACTIONLINT_VERSION"))
        r = self.run_main("extra-arg")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.calls.read_text().split("\n")[:4],
            ["-oneline", "-shellcheck", str(shellcheck), "extra-arg"],
        )
        self.assertIn(f"shellcheck: {shellcheck}", r.stdout)

    def test_actionlint_の結論をそのまま返す(self):
        self.stub(self.bin / "shellcheck", "--version", f"version: {pinned_version('SHELLCHECK_VERSION')}")
        self.stub(self.bin / "actionlint", "-version", pinned_version("ACTIONLINT_VERSION"))
        r = self.run_main(FAKE_RC="3")
        self.assertEqual(r.returncode, 3)

    def test_PATH_の版が違えば置き場のピンを使う(self):
        # 置き場 (.build/tools) に済んだピンがあれば取りに行かない
        self.stub(self.bin / "shellcheck", "--version", "version: 0.0.1")
        self.stub(self.bin / "actionlint", "-version", "0.0.1")
        tools = self.root / ".build" / "tools"
        pinned_sc = tools / f"shellcheck-{pinned_version('SHELLCHECK_VERSION')}"
        pinned_al = tools / f"actionlint-{pinned_version('ACTIONLINT_VERSION')}"
        self.stub(pinned_sc, "--version", f"version: {pinned_version('SHELLCHECK_VERSION')}")
        self.stub(pinned_al, "-version", pinned_version("ACTIONLINT_VERSION"))
        r = self.run_main()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls.read_text().split("\n")[:3], ["-oneline", "-shellcheck", ".build/tools/" + pinned_sc.name])
        self.assertIn(f"actionlint: .build/tools/{pinned_al.name}", r.stdout)


class PickAssetsTest(unittest.TestCase):
    """落とす配布物を機械の種類で選ぶ (#2612)。

    CI ではこの段を ubuntu (x86_64) の ci-static が走らせ、手元は macOS / Apple Silicon で
    走る。取り違えると、照合値の合わない配布物か、走らない種類の実行ファイルを落とす。
    `uname` は PATH の先に置いた代役が名乗る。
    """

    def pick(self, system: str, machine: str) -> subprocess.CompletedProcess:
        bin_dir = Path(tempfile.mkdtemp(prefix="pick-assets-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(bin_dir)])
        stub = bin_dir / "uname"
        stub.write_text(
            f'#!/bin/sh\ncase "$1" in -s) echo {system} ;; -m) echo {machine} ;; esac\n'
        )
        stub.chmod(0o755)
        command = (
            f'PATH="{bin_dir}:$PATH"; source "{SCRIPT}"; pick_assets; '
            'printf "%s\\n" "$ACTIONLINT_ASSET" "$ACTIONLINT_SHA256" "$SHELLCHECK_ASSET" "$SHELLCHECK_SHA256"'
        )
        return subprocess.run(
            ["/bin/bash", "-c", command], cwd=REPO, capture_output=True, text=True, timeout=60,
        )

    def test_ubuntu_の_x86_64_では_linux_の配布物を選ぶ(self):
        result = self.pick("Linux", "x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        actionlint, actionlint_sha, shellcheck, shellcheck_sha = result.stdout.split()
        self.assertRegex(actionlint, r"^actionlint_[0-9.]+_linux_amd64\.tar\.gz$")
        self.assertRegex(shellcheck, r"^shellcheck-v[0-9.]+\.linux\.x86_64\.tar\.gz$")
        self.assertRegex(actionlint_sha, r"^[0-9a-f]{64}$")
        self.assertRegex(shellcheck_sha, r"^[0-9a-f]{64}$")

    def test_手元の_Apple_Silicon_では_darwin_の配布物を選ぶ(self):
        result = self.pick("Darwin", "arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        actionlint, actionlint_sha, shellcheck, shellcheck_sha = result.stdout.split()
        self.assertRegex(actionlint, r"^actionlint_[0-9.]+_darwin_arm64\.tar\.gz$")
        self.assertRegex(shellcheck, r"^shellcheck-v[0-9.]+\.darwin\.aarch64\.tar\.gz$")
        # 種類ごとに照合値が違う (片方の値の写し忘れを拾う)
        linux = self.pick("Linux", "x86_64").stdout.split()
        self.assertNotEqual(actionlint_sha, linux[1])
        self.assertNotEqual(shellcheck_sha, linux[3])

    def test_想定外の機械では落とさずに止まる(self):
        result = self.pick("Linux", "aarch64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("手で入れて PATH に通す", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
