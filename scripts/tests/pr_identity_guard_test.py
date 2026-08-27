#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/pr-identity-guard.sh の検査 (#103)。

守りたいのは 1 つ — **メンテナ名義で PR を作ろうとしたら、作る前に差し戻される**。
破ると誰も承認できない PR ができ、close して作り直すしかない (ADR-0007 / #88)。

判定はコマンド文字列と GH_TOKEN だけを見るので、ネットワークも gh も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "scripts" / "pr-identity-guard.sh"

TOKEN_ENV = ["GH_TOKEN", "GITHUB_TOKEN"]


def clean_env(**overrides):
    """token 系の環境変数を必ず立て直す。

    このテスト自体がエージェントのセッションから走るため、素の環境を引き継ぐと
    「判定できた」のか「呼び出し元の env が漏れた」のか区別できない。
    """
    env = {k: v for k, v in os.environ.items() if k not in TOKEN_ENV}
    env.update(overrides)
    return env


class GuardTest(unittest.TestCase):
    """PreToolUse フック: どのコマンドを差し戻し、どれを素通しするか。"""

    def run_guard(self, command, **env):
        payload = json.dumps({"tool_input": {"command": command}})
        proc = subprocess.run(
            ["bash", str(GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            env=clean_env(**env),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def assert_denied(self, command, **env):
        out = self.run_guard(command, **env)
        self.assertTrue(out, f"差し戻されるはずが素通しした: {command}")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        return decision["permissionDecisionReason"]

    def assert_passed(self, command, **env):
        self.assertEqual(
            self.run_guard(command, **env), "", f"素通しのはずが差し戻された: {command}"
        )

    # --- 差し戻すもの ---------------------------------------------------

    def test_bare_pr_create_denied(self):
        self.assert_denied('gh pr create --title "x" --body "y"')

    def test_personal_token_denied(self):
        """個人の token では author が人間になる。ghs_ 以外は通さない。"""
        self.assert_denied("gh pr create --fill", GH_TOKEN="gho_" + "x" * 36)

    def test_global_option_before_subcommand_denied(self):
        """gh -R owner/repo pr create のように、サブコマンドの手前に options が来る形。"""
        self.assert_denied("gh -R mokume-metal/mokume pr create --fill")

    def test_this_repo_explicitly_denied(self):
        self.assert_denied("gh pr create -R mokume-metal/mokume --fill")

    def test_ambiguous_repo_denied(self):
        """owner を省いた --repo は自リポか判定できない。曖昧なら止める側に倒す。"""
        self.assert_denied("gh pr create --repo mokume --fill")

    def test_reason_shows_how_to_get_a_token(self):
        reason = self.assert_denied("gh pr create --fill")
        self.assertIn("scripts/gh-app-token.sh", reason)

    def test_reason_tells_not_to_conclude_the_key_is_missing(self):
        """ADR-0007 決定 5 — 鍵が無いと即断させない。在処ではなく探し方を示す。"""
        reason = self.assert_denied("gh pr create --fill")
        self.assertIn("一覧", reason)

    def test_reason_does_not_leak_where_the_key_lives(self):
        """在処も道具名もメッセージに出さない (ADR-0003 / ADR-0007 決定 5)。"""
        reason = self.assert_denied("gh pr create --fill")
        for leak in ("op://", "1Password", "Keychain", "secret-read"):
            self.assertNotIn(leak, reason)

    # --- 素通しするもの -------------------------------------------------

    def test_app_token_command_passes(self):
        """実際の運用形 — 同じ行で installation token を発行してから作る。"""
        self.assert_passed(
            'export GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )

    def test_installation_token_in_env_passes(self):
        """常設している環境。"""
        self.assert_passed("gh pr create --fill", GH_TOKEN="ghs_" + "x" * 36)

    def test_read_only_commands_pass(self):
        self.assert_passed("gh pr view 105")
        self.assert_passed("gh pr checks 105")
        self.assert_passed("gh pr list --state open")
        self.assert_passed("gh pr diff 105")

    def test_help_passes(self):
        self.assert_passed("gh pr create --help")
        self.assert_passed("gh pr create -h")

    def test_other_repo_passes(self):
        """他のリポジトリ宛ての PR はこのリポジトリの規約の外。"""
        self.assert_passed("gh pr create -R shinyaoguri/claude-plugins --fill")
        self.assert_passed("gh pr create --repo=other/repo --fill")

    def test_non_gh_command_passes(self):
        self.assert_passed("git commit -m 'gh pr create'")
        self.assert_passed("echo hello")


class WiringTest(unittest.TestCase):
    """配線 — 書いただけで settings.json に繋がっていなければ効かない。"""

    def test_hook_is_wired_into_settings(self):
        settings = json.loads((REPO / ".claude" / "settings.json").read_text())
        commands = [
            hook["command"]
            for entry in settings["hooks"]["PreToolUse"]
            if entry.get("matcher") == "Bash"
            for hook in entry["hooks"]
        ]
        self.assertTrue(
            any("pr-identity-guard.sh" in c for c in commands),
            "pr-identity-guard.sh が PreToolUse(Bash) に配線されていない",
        )


if __name__ == "__main__":
    unittest.main()
