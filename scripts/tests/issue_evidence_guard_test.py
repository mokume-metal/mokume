#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/issue-evidence-guard.sh の検査 (#2195)。

フックが守るのは 1 つ — **描画のファイルを名指しする Issue の本文を、絵も宣言も無いまま
gh issue create / edit で出させない**こと。照合そのものは check-drawing-evidence.sh の
--issue-body が持つ (drawing_evidence_test.IssueBodyTest)。ここでは本文の取り出し方と、
素通しにすべき呼び出し (他のリポジトリ宛て・本文の無い edit・--help・コメント) を固定する。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "scripts" / "issue-evidence-guard.sh"

DRAWING_BODY = "`Shapes.metal` の mokume_formPaint が細い塗りで透ける"


class IssueEvidenceGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def body_file(self, text, name="body.md"):
        path = self.dir / name
        path.write_text(text, encoding="utf-8")
        return path

    def run_guard(self, command, cwd=None):
        payload = json.dumps({"tool_input": {"command": command}, "cwd": str(cwd or REPO)})
        env = {k: v for k, v in os.environ.items() if k not in ("GH_REPO", "DRAWING_PATHS")}
        proc = subprocess.run(
            ["/bin/bash", str(GUARD)], input=payload, capture_output=True, text=True,
            encoding="utf-8", env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def assert_denied(self, command, cwd=None):
        out = self.run_guard(command, cwd)
        self.assertTrue(out, f"差し戻されるはずが素通しした: {command}")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        return decision["permissionDecisionReason"]

    def assert_passed(self, command, cwd=None):
        self.assertEqual(self.run_guard(command, cwd), "", f"素通しのはずが差し戻された: {command}")

    # --- 差し戻すもの -----------------------------------------------------

    def test_body_file_naming_drawing_without_picture_is_denied(self):
        path = self.body_file(DRAWING_BODY)
        reason = self.assert_denied(f"gh issue create --title t --body-file {path}")
        self.assertIn("Shapes.metal", reason)
        self.assertIn("絵: なし — <理由>", reason)

    def test_relative_body_file_is_read_from_cwd(self):
        self.body_file(DRAWING_BODY)
        self.assert_denied("gh issue create -t t -F body.md", cwd=self.dir)

    def test_inline_body_is_denied(self):
        self.assert_denied(f"gh issue create --title t --body '{DRAWING_BODY}'")

    def test_edit_is_denied(self):
        path = self.body_file(DRAWING_BODY)
        self.assert_denied(f"gh issue edit 12 --body-file={path}")

    def test_inside_a_compound_command_is_denied(self):
        path = self.body_file(DRAWING_BODY)
        self.assert_denied(f'url=$(gh issue create --title t --body-file {path}) && echo "$url"')

    # --- 素通しするもの ---------------------------------------------------

    def test_picture_passes(self):
        path = self.body_file(DRAWING_BODY + "\n\n![漏れ](https://i.gyazo.com/abc.png)")
        self.assert_passed(f"gh issue create --title t --body-file {path}")

    def test_declaration_passes_even_inline(self):
        # 引用の中の改行は戻らないので、宣言が行頭に来なくても通す
        self.assert_passed(f"gh issue create --title t --body '{DRAWING_BODY}\n\n絵: なし — 落ちるだけ'")

    def test_non_drawing_body_passes(self):
        path = self.body_file("scripts/release.py のタグの付け方")
        self.assert_passed(f"gh issue create --title t --body-file {path}")

    def test_other_repository_passes(self):
        path = self.body_file(DRAWING_BODY)
        self.assert_passed(f"gh issue create -R someone/else --title t --body-file {path}")

    def test_edit_without_body_passes(self):
        self.assert_passed("gh issue edit 12 --add-label 'status: in progress'")

    def test_comment_is_not_this_guards_business(self):
        self.assert_passed(f"gh issue comment 12 --body '{DRAWING_BODY}'")

    def test_help_passes(self):
        self.assert_passed("gh issue create --help")

    def test_unreadable_body_file_passes(self):
        self.assert_passed("gh issue create --title t --body-file /nonexistent/body.md")

    def test_stdin_body_file_passes(self):
        self.assert_passed(f"echo '{DRAWING_BODY}' | gh issue create --title t --body-file -")

    def test_mentioning_the_command_in_a_commit_message_passes(self):
        self.assert_passed('git commit -m "gh issue create --body Shapes.metal の扱い"')


if __name__ == "__main__":
    unittest.main()
