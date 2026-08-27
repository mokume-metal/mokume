#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/comment.sh と scripts/agent-comment-guard.sh の検査 (#18)。

守りたいのは 2 つ:
  1. 素の gh でコメントしようとしたら差し戻される (付け忘れの経路を塞ぐ)
  2. ラッパー経由なら、どの AI が書いたかの署名が自動で付く

gh は PATH のスタブに差し替えるので、ネットワークも認証も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
COMMENT = REPO / "scripts" / "comment.sh"
GUARD = REPO / "scripts" / "agent-comment-guard.sh"

# エージェント検出に関わる環境変数。テストの中では毎回まっさらにしてから
# 必要なものだけ立てる (このテスト自体がエージェントのセッションから走るため、
# 素の環境を引き継ぐと「検出できた」のか「呼び出し元の env が漏れた」のか区別できない)
AGENT_ENV = [
    "MOKUME_AGENT_NAME",
    "MOKUME_AGENT_URL",
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "AI_AGENT",
    "CODEX_SANDBOX",
    "CODEX_SANDBOX_NETWORK_DISABLED",
    "CODEX_HOME",
]


def clean_env(**overrides):
    env = {k: v for k, v in os.environ.items() if k not in AGENT_ENV}
    env.update(overrides)
    return env


class GuardTest(unittest.TestCase):
    """PreToolUse フック: どのコマンドを差し戻し、どれを素通しするか。"""

    def run_guard(self, command):
        payload = json.dumps({"tool_input": {"command": command}})
        proc = subprocess.run(
            ["bash", str(GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def assert_denied(self, command):
        out = self.run_guard(command)
        self.assertTrue(out, f"差し戻されるはずが素通しした: {command}")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("scripts/comment.sh", decision["permissionDecisionReason"])

    def assert_passed(self, command):
        self.assertEqual(self.run_guard(command), "", f"素通しのはずが差し戻された: {command}")

    def test_bare_issue_comment_denied(self):
        self.assert_denied('gh issue comment 1 --body "x"')

    def test_bare_pr_comment_denied(self):
        self.assert_denied("gh pr comment 7 -F /tmp/body.md")

    def test_repo_option_before_subcommand_denied(self):
        # gh -R owner/repo issue comment ... のように前置オプションが挟まる形
        self.assert_denied("gh -R mokume-metal/mokume issue comment 1 --body x")

    def test_review_with_body_denied(self):
        self.assert_denied('gh pr review 3 --approve --body "見ました"')

    def test_review_without_body_passes(self):
        # 発言を伴わない Approve は署名の対象ではない
        self.assert_passed("gh pr review 3 --approve")

    # --- close / reopen に添える発言 (#123) -----------------------------

    def test_close_with_comment_denied(self):
        """閉じながらの発言も発言。#120 に未署名のコメントが残った形。"""
        self.assert_denied('gh pr close 120 -c "メンテナ名義だったので閉じる"')
        self.assert_denied('gh pr close 120 --comment "閉じる"')
        self.assert_denied("gh pr close 120 --comment=閉じる")
        self.assert_denied('gh issue close 42 -c "対応済み"')

    def test_reopen_with_comment_denied(self):
        self.assert_denied('gh issue reopen 42 --comment "やり直す"')
        self.assert_denied('gh pr reopen 120 -c "取り消す"')

    def test_close_with_comment_and_leading_option_denied(self):
        self.assert_denied('gh -R mokume-metal/mokume pr close 120 -c "理由"')

    def test_close_without_comment_passes(self):
        """状態を変えるだけなら発言が無い (--approve だけのレビューと同じ扱い)。"""
        self.assert_passed("gh pr close 120")
        self.assert_passed("gh pr close 120 --delete-branch")
        self.assert_passed('gh issue close 42 --reason "not planned"')
        self.assert_passed("gh issue reopen 42")

    def test_c_option_meaning_something_else_passes(self):
        """-c の意味は gh の中で衝突している。読み取りまで止めてはいけない。

        サブコマンドを絞らずオプションだけで判定すると、ここが全部赤になる。
        """
        self.assert_passed("gh pr view 121 -c")  # --comments (コメントを読む)
        self.assert_passed("gh issue view 42 -c")
        self.assert_passed("gh issue view 42 --comments")
        self.assert_passed("gh issue develop 42 -c")  # --checkout

    def test_merge_body_passes(self):
        """マージコミットの本文はスレッドへの発言ではない (境界)。"""
        self.assert_passed('gh pr merge 125 --auto --squash --body "マージ本文"')

    def test_close_reason_shows_the_two_step_procedure(self):
        """差し戻すだけでは直せない。ラッパーには close 機能が無いので手順を示す。"""
        out = self.run_guard('gh pr close 120 -c "理由"')
        reason = json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("gh pr close <番号>", reason)

    def test_read_only_commands_pass(self):
        self.assert_passed("gh issue view 1")
        self.assert_passed("gh pr list")
        self.assert_passed("gh api repos/mokume-metal/mokume/issues/1")

    def test_help_passes(self):
        self.assert_passed("gh issue comment --help")

    def test_wrapper_passes(self):
        self.assert_passed("bash scripts/comment.sh issue 1 --body x")
        self.assert_passed("bash /abs/path/scripts/comment.sh pr 2 -F /tmp/x.md")

    def test_non_gh_command_passes(self):
        self.assert_passed("make ci-check")


class SignatureTest(unittest.TestCase):
    """ラッパー: 署名を誰の名前で、どう付けるか。"""

    def dry_run(self, body="本文", **env):
        proc = subprocess.run(
            ["bash", str(COMMENT), "issue", "42", "--body", body, "--dry-run"],
            capture_output=True,
            text=True,
            env=clean_env(**env),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout, proc.stderr

    def test_claude_code_detected(self):
        out, _ = self.dry_run(CLAUDECODE="1")
        self.assertIn("Assisted by [Claude Code](https://claude.com/claude-code)", out)

    def test_claude_code_detected_via_ai_agent(self):
        out, _ = self.dry_run(AI_AGENT="claude-code_2-1-241_agent")
        self.assertIn("Assisted by [Claude Code]", out)

    def test_codex_detected(self):
        out, _ = self.dry_run(CODEX_SANDBOX="seatbelt")
        self.assertIn("Assisted by [OpenAI Codex]", out)
        self.assertNotIn("Claude Code", out)

    def test_explicit_name_wins(self):
        out, _ = self.dry_run(MOKUME_AGENT_NAME="Cursor", CLAUDECODE="1")
        self.assertIn("Assisted by Cursor", out)
        self.assertNotIn("Claude Code", out)

    def test_explicit_name_with_url(self):
        out, _ = self.dry_run(
            MOKUME_AGENT_NAME="Cursor", MOKUME_AGENT_URL="https://cursor.com"
        )
        self.assertIn("Assisted by [Cursor](https://cursor.com)", out)

    def test_unknown_agent_posts_with_generic_signature(self):
        # 検出できなくても投稿は止めない (止めるとラッパーが使われなくなる)
        out, err = self.dry_run()
        self.assertIn("Assisted by an AI agent", out)
        self.assertIn("MOKUME_AGENT_NAME", err)

    def test_existing_signature_not_duplicated(self):
        body = "本文\n\n---\n<sub>🤖 Assisted by [Claude Code](https://claude.com/claude-code)</sub>"
        out, _ = self.dry_run(body=body, CLAUDECODE="1")
        self.assertEqual(out.count("Assisted by"), 1)

    def test_body_file_is_read(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "body.md"
            f.write_text("ファイルからの本文\n", encoding="utf-8")
            proc = subprocess.run(
                ["bash", str(COMMENT), "pr", "7", "--body-file", str(f), "--dry-run"],
                capture_output=True,
                text=True,
                env=clean_env(CLAUDECODE="1"),
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("ファイルからの本文", proc.stdout)
            self.assertIn("Assisted by [Claude Code]", proc.stdout)

    def test_missing_body_is_an_error(self):
        proc = subprocess.run(
            ["bash", str(COMMENT), "issue", "1", "--dry-run"],
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_bad_kind_is_an_error(self):
        proc = subprocess.run(
            ["bash", str(COMMENT), "discussion", "1", "--body", "x"],
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        self.assertNotEqual(proc.returncode, 0)


class DocumentationTest(unittest.TestCase):
    """AGENTS.md と実装が食い違わないようにする。

    フックが強制できるのは Claude Code のセッションだけで、他のエージェントと人間には
    AGENTS.md しか届かない。だから両方に書く必要がある — ただし**同じことを二度書かない**。
    「何をすべきか」は AGENTS.md、「どう実現するか」(署名の文字列・検出の順序) は
    スクリプトにだけ置き、ここでその境界が保たれているかを見る。
    """

    def setUp(self):
        self.agents_md = (REPO / "AGENTS.md").read_text(encoding="utf-8")

    def test_agents_md_points_at_the_wrapper(self):
        # ラッパーを改名したらここで気付く (ドキュメントが古いパスを指し続けない)
        self.assertIn("scripts/comment.sh", self.agents_md)
        self.assertTrue(COMMENT.exists())

    def test_agents_md_does_not_restate_the_signature(self):
        # 署名の文字列を文書側にも書くと、変えたときに片方が古くなる。
        # 正本は scripts/comment.sh の signature() だけ
        self.assertNotIn("<sub>🤖", self.agents_md)


class GhInvocationTest(unittest.TestCase):
    """実際に gh へ渡す形 — 本文はファイル経由、リポジトリは明示する。

    投稿先の推定は事故のもとで、cwd の git リポジトリを文脈に取ると別のリポジトリの
    同じ番号へ飛ぶ。-R を必ず添えることをここで固定する。
    """

    def test_gh_receives_repo_and_body_file(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            log = d / "argv.txt"
            stub = d / "gh"
            stub.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$@" > "$LOG"\n'
                'for a in "$@"; do :; done\n'
                'cat "${!#}" >> "$LOG"\n',
                encoding="utf-8",
            )
            stub.chmod(0o755)
            env = clean_env(
                CLAUDECODE="1",
                PATH=f"{d}:{os.environ['PATH']}",
                LOG=str(log),
                GITHUB_REPOSITORY="mokume-metal/mokume",
            )
            proc = subprocess.run(
                ["bash", str(COMMENT), "issue", "42", "--body", "投稿本文"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            captured = log.read_text(encoding="utf-8")
            self.assertIn("issue", captured)
            self.assertIn("comment", captured)
            self.assertIn("42", captured)
            self.assertIn("mokume-metal/mokume", captured)
            self.assertIn("投稿本文", captured)
            self.assertIn("Assisted by [Claude Code]", captured)


if __name__ == "__main__":
    unittest.main()
