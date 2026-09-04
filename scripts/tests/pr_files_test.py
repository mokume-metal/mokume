#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/pr-files.sh の検査 (#793)。

守りたいのは 1 つ — **「この PR が触ったファイル」の取り方が 1 つで、必ず全件を引く**。

取り方が 2 通りあった頃、片方 (`gh pr view --json files`) は GraphQL の接続を引くので
上限があり、大きな PR では後半のファイルが落ちた。落ちた先で起きるのは、保護パスの
検査が素通りする・絵の証跡の要求が外れる、という**赤くならずに緩む**壊れ方である。

だから固定するのは 2 つ:

1. **取り方の中身** — `--paginate` を通ること / リポジトリを省いても引けること /
   読めなければ非 0 で何も出さないこと
2. **取り方が 1 つであること** — `scripts/*.sh` を glob して、上限のある口が
   戻ってこないことを見る (**一覧は数え上げない**ので、7 本目のスクリプトが
   上限のある口を使ったらそこで赤くなる)

**新しい検査 (Makefile の的) は足さない。** `make hooks-test` が `-p '*_test.py'` で
discover するので、ここに 1 ファイル置けば CI にも載る (`bash_invocation_test.py` /
`surface_vocabulary_test.py` と同じ構え・ADR-0008 決定 5 段 1)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"
LIB = SCRIPTS / "pr-files.sh"

# 呼ばれた引数を記録して、作り物の一覧を返す gh。GH_FAILS を立てると読めない機械を装う
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
[ -z "${GH_FAILS:-}" ] || { echo "gh: 500" >&2; exit 1; }
printf '%s\\n' ${FAKE_FILES:-}
"""


class PrFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)
        self.calls = root / "gh-calls.txt"
        self.env = dict(os.environ)
        self.env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            GH_CALLS=str(self.calls),
            FAKE_FILES="a.swift b.swift",
        )

    def call(self, repo, number="7", **env):
        self.env.update(env)
        return subprocess.run(
            ["/bin/bash", "-c", f'. "{LIB}"\npr_files "$1" "$2"', "_", repo, number],
            capture_output=True,
            text=True,
            env=self.env,
        )

    def gh_args(self):
        return self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""

    def test_paths_come_back_one_per_line(self):
        proc = self.call("owner/name")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.split(), ["a.swift", "b.swift"])

    def test_the_call_paginates(self):
        """**ここが現象そのもの。** ページングを外すと後半のファイルが落ちる。"""
        self.call("owner/name")
        self.assertIn("--paginate", self.gh_args())

    def test_the_call_names_the_repository_and_the_number(self):
        self.call("owner/name", "42")
        self.assertIn("repos/owner/name/pulls/42/files", self.gh_args())

    def test_an_empty_repository_falls_back_to_the_placeholder(self):
        """`GITHUB_REPOSITORY` の無い手元から走る呼び出し側のため (check-drawing-evidence)。

        倒さないと、呼び出し側が `gh repo view` でリポジトリ解決を 1 回増やすことになる。
        """
        proc = self.call("", "42")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("repos/{owner}/{repo}/pulls/42/files", self.gh_args())

    def test_unreadable_is_a_failure_with_no_output(self):
        """**読めなかったことを空の一覧と混ぜない。**

        混ぜると「触っていない」と読めてしまい、まさにこの Issue が塞いだ緩み方に戻る。
        逃がしは呼び出し側が持つ (どのスクリプトも「読めなかった」分岐を書いている)。
        """
        proc = self.call("owner/name", "42", GH_FAILS="1")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")

    def test_a_missing_number_is_refused(self):
        proc = self.call("owner/name", "")
        self.assertNotEqual(proc.returncode, 0)


class OneWayOnlyTest(unittest.TestCase):
    """**取り方が 1 つであることを構造で見る。**

    一覧は数え上げない — `scripts/*.sh` を glob するので、7 本目のスクリプトが上限の
    ある口を使ったらそこで赤くなる (`bash_invocation_test.py` が検査ファイル全体を
    glob して `/bin/bash` を見張っているのと同じ構え)。
    """

    def scripts(self):
        found = sorted(SCRIPTS.glob("*.sh"))
        # 対象が 0 件の緑は、通っていることに意味が無い (置き場の移動を緑のまま
        # 見逃さないため。check-file-modes.sh と同じ構え)
        self.assertTrue(found, f"検査対象の *.sh が 1 つも無い ({SCRIPTS})")
        return found

    def offending(self, pattern, message, allow=()):
        found = []
        for path in self.scripts():
            if path.name in allow:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if re.search(pattern, line):
                    found.append(f"  {path.name}:{number}: {line.strip()}")
        if found:
            self.fail(message + "\n" + "\n".join(found))

    def test_no_script_asks_gh_pr_view_for_the_files(self):
        """`gh pr view --json …files` は上限のある口。**これが落ちる側である。**"""
        self.offending(
            r"gh pr view.*--json[^|;)]*\bfiles\b",
            "上限のある口で変更ファイルを取っている箇所がある\n"
            "(pr_files を通すこと — gh pr view の files は GraphQL の接続で、\n"
            "大きな PR では後半が落ちる。落ちても赤くならない):",
        )

    def test_only_the_library_reaches_for_the_files_endpoint(self):
        """全件を引く口も 1 箇所に保つ。写しが増えると `--paginate` の付け忘れが戻る。"""
        self.offending(
            r"pulls/[^\"']*/files",
            "変更ファイルの口を自前で引いている箇所がある (pr_files を通すこと):",
            allow=("pr-files.sh",),
        )

    def test_the_library_is_not_empty(self):
        """畳んだ先が空になっていない (この検査自身が空回りしていたら赤くする)。"""
        text = LIB.read_text(encoding="utf-8")
        self.assertIn("--paginate", text)
        self.assertIn("pr_files()", text)

    def test_every_reader_sources_the_library(self):
        """使う側が source していなければ、`pr_files: command not found` で落ちる。"""
        for name in (
            "review-gate.sh",
            "check-drawing-evidence.sh",
            "catch-up.sh",
            "render-status.sh",
        ):
            with self.subTest(reader=name):
                text = (SCRIPTS / name).read_text(encoding="utf-8")
                self.assertIn("pr-files.sh", text, f"{name} が pr-files.sh を読んでいない")


if __name__ == "__main__":
    unittest.main()
