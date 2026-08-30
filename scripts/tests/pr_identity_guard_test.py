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
import re
import subprocess
import tempfile
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

    def run_guard(self, command, cwd=None, **env):
        payload = json.dumps(
            {"tool_input": {"command": command}, **({"cwd": cwd} if cwd else {})}
        )
        proc = subprocess.run(
            ["/bin/bash", str(GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            env=clean_env(**env),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def assert_denied(self, command, cwd=None, **env):
        out = self.run_guard(command, cwd=cwd, **env)
        self.assertTrue(out, f"差し戻されるはずが素通しした: {command}")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        return decision["permissionDecisionReason"]

    def assert_passed(self, command, cwd=None, **env):
        self.assertEqual(
            self.run_guard(command, cwd=cwd, **env),
            "",
            f"素通しのはずが差し戻された: {command}",
        )

    def other_repo_dir(self):
        """別のリポジトリの作業ディレクトリを 1 つ用意する。"""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "theirs"
        root.mkdir()
        run = lambda *a: subprocess.run(["git", *a], cwd=root, check=True,
                                        capture_output=True)
        run("init", "-q")
        # 使い捨てのリポジトリでは署名を切る (#344)
        run("config", "commit.gpgsign", "false")
        run("remote", "add", "origin", "git@github.com:shinyaoguri/setup.git")
        return str(root)

    # --- 宛先がこのリポジトリでないもの (#611) --------------------------

    def test_other_repository_by_working_directory_is_passed(self):
        """別リポジトリのディレクトリから打った PR 作成は、この規約の外。

        -R が無いだけで差し戻していたのが #611。あちらに ADR-0007 の不変条件は
        無いので、メンテナ名義で作って何も問題がない。
        """
        self.assert_passed("gh pr create --fill", cwd=self.other_repo_dir())

    def test_this_repository_named_from_another_directory_is_denied(self):
        """別リポのディレクトリからでも、-R でこのリポジトリを名指ししたら止める。"""
        self.assert_denied(
            "gh pr create -R mokume-metal/mokume --fill", cwd=self.other_repo_dir()
        )

    def test_undecidable_directory_is_denied_with_the_escape_hatch(self):
        """宛先を決められないものは止めるが、逃げ道を示す。"""
        with tempfile.TemporaryDirectory() as plain:
            reason = self.assert_denied("gh pr create --fill", cwd=plain)
        self.assertIn("-R owner/repo", reason, "逃げ道が案内されていない")

    def test_reason_does_not_assert_what_may_be_false(self):
        """「誰も承認できない PR になる」は、このリポジトリ宛てに限った話である。"""
        reason = self.assert_denied("gh pr create --fill")
        self.assertIn("このリポジトリ宛て", reason)

    # --- 差し戻すもの ---------------------------------------------------

    def test_bare_pr_create_denied(self):
        self.assert_denied('gh pr create --title "x" --body "y"')

    def test_personal_token_denied(self):
        """個人の token では author が人間になる。ghs_ 以外は通さない。"""
        self.assert_denied("gh pr create --fill", GH_TOKEN="gho_" + "x" * 36)

    # --- 以前は見逃していた形 (#128) ------------------------------------
    #
    # 素通りすると **メンテナ名義の PR がそのまま作られる**。承認できる人が居ない
    # PR になり、close して作り直すしかない (ADR-0007 / #88)。

    def test_command_substitution_denied(self):
        self.assert_denied("url=$(gh pr create --fill)")

    def test_subshell_denied(self):
        self.assert_denied("(gh pr create --fill)")

    def test_backticks_denied(self):
        self.assert_denied("url=`gh pr create --fill`")

    # --- 地の文で言及しただけなら止めない (#128) ------------------------
    #
    # 止めると回避策 (ファイルに逃がす) が身について、guard を迂回する手癖がつく。

    def test_mention_in_commit_message_passes(self):
        self.assert_passed(
            "git commit -F - <<'EOF'\n"
            "guard が gh pr create を差し戻すようにした。\n"
            "EOF"
        )

    def test_mention_in_quoted_argument_passes(self):
        self.assert_passed("echo '素の gh pr create は差し戻される'")

    def test_global_option_before_subcommand_denied(self):
        """gh -R owner/repo pr create のように、サブコマンドの手前に options が来る形。"""
        self.assert_denied("gh -R mokume-metal/mokume pr create --fill")

    def test_this_repo_explicitly_denied(self):
        self.assert_denied("gh pr create -R mokume-metal/mokume --fill")

    def test_ambiguous_repo_denied(self):
        """owner を省いた --repo は自リポか判定できない。曖昧なら止める側に倒す。"""
        self.assert_denied("gh pr create --repo mokume --fill")

    # --- token 発行の失敗を握り潰す形 (#122) ----------------------------
    #
    # いずれも「token を発行しようとはしている」が、発行が失敗しても後段が走る。
    # 空の GH_TOKEN で gh がメンテナの認証へフォールバックし、#120 と同じ詰みになる。

    def test_export_prefixed_assignment_denied(self):
        """export V="$(…)" は export 自身の終了コード (0) を返す。#120 の形。"""
        self.assert_denied(
            'export GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )

    def test_assignment_prefix_denied(self):
        """代入プレフィクス V="$(…)" cmd も発行の失敗が伝わらない。"""
        self.assert_denied(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" gh pr create --fill'
        )

    def test_set_e_does_not_rescue_export_form(self):
        """set -e は救わない — export の終了コードが 0 だから発火しない。"""
        self.assert_denied(
            'set -e; export GH_TOKEN="$(bash scripts/gh-app-token.sh)";'
            " gh pr create --fill"
        )

    def test_unsafe_form_denied_even_with_installation_token_in_env(self):
        """env に ghs_ があっても、危険な形はそれを空文字で上書きしてしまう。

        「常設 token があるなら通す」判定が先に効くと、この握り潰しを見逃す。
        """
        self.assert_denied(
            'export GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill',
            GH_TOKEN="ghs_" + "x" * 36,
        )

    def test_unsafe_form_reason_shows_the_safe_form(self):
        """差し戻すだけでは直せない。安全な形をそのまま示す。"""
        reason = self.assert_denied(
            'export GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )
        self.assertIn('GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN', reason)

    def test_unsafe_form_reason_does_not_leak_where_the_key_lives(self):
        """新しいメッセージにも既存の観点を当てる (ADR-0003 / ADR-0007 決定 5)。"""
        reason = self.assert_denied(
            'export GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )
        for leak in ("op://", "1Password", "Keychain", "secret-read"):
            self.assertNotIn(leak, reason)

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

    def test_assignment_without_export_denied(self):
        """**発行できただけでは足りない。**

        素の代入はそのシェルの変数を作るだけで、子プロセスの gh には渡らない。
        「発行の失敗が伝わる形」は満たしているので気付きにくく、実際に #279 が
        これで詰んだ (#285)。
        """
        reason = self.assert_denied(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )
        self.assertIn("gh へ渡っていません", reason)

    def test_assignment_without_export_denied_with_other_commands_between(self):
        """間に別のコマンドを挟んでも同じ。実際に踏んだ形はこれだった。"""
        reason = self.assert_denied(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && git push -q -u origin feat/x'
            " && gh pr create --fill"
        )
        self.assertIn("gh へ渡っていません", reason)

    def test_not_exported_reason_shows_the_safe_form(self):
        reason = self.assert_denied(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )
        self.assertIn(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN', reason
        )

    def test_not_exported_reason_names_the_second_trap(self):
        """閉じて作り直しても解けないことまで書く — そこが一番払う代償が大きい。"""
        reason = self.assert_denied(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr create --fill'
        )
        self.assertIn("閉じて作り直しても解けません", reason)

    def test_export_of_another_variable_does_not_count(self):
        """別の変数を export しているだけでは渡ったことにならない。"""
        reason = self.assert_denied(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export OTHER_TOKEN'
            " && gh pr create --fill"
        )
        self.assertIn("gh へ渡っていません", reason)

    # --- 素通しするもの -------------------------------------------------

    def test_app_token_command_passes(self):
        """実際の運用形 — 同じ行で installation token を発行してから作る。

        素の代入から始めるのが要点。代入は右辺の終了コードをそのまま返すので、
        発行に失敗すれば && が切れて gh pr create に届かない (#122)。
        """
        self.assert_passed(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN'
            " && gh pr create --fill"
        )

    def test_app_token_command_passes_across_lines(self):
        """前段に別の設定を置く実運用の形。判定は行をまたいでも効く。"""
        self.assert_passed(
            'export MOKUME_APP_PRIVATE_KEY_CMD="読み出しコマンド"\n'
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN'
            " && gh pr create --fill"
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


class PushFormTest(unittest.TestCase):
    """案内する push は、そのまま打って通る形でなければならない (#376)。

    upstream の無いブランチで素の `git push` は必ず落ちる。落ちる形を見せると、読んだ側は
    その場で各自の形に書き換えて凌ぐことになり、**`-u` が付くかどうかが経路ごとに変わる**。
    付かなかったブランチは merge されても `[gone]` にならないので、`git gone-clean` が
    永久に拾えない — 実測で 18 本中 16 本が残っていた。

    突き合わせるのは「`git push` の直後に `-u` があるか」だけにする。文言そのものを固定
    すると、案内の言い回しを直すたびにこちらが赤くなる。
    """

    # 案内が置かれる場所。作法の正典 (AGENTS.md) と、差し戻しのときに読まれる guard
    SOURCES = ("AGENTS.md", "scripts/pr-identity-guard.sh")

    def test_案内する_push_は_upstream_を張る形になっている(self):
        pattern = re.compile(r"git push(?![-\w])(.*)$")
        for name in self.SOURCES:
            text = (REPO / name).read_text(encoding="utf-8")
            for number, line in enumerate(text.splitlines(), 1):
                found = pattern.search(line)
                if not found:
                    continue
                with self.subTest(f"{name}:{number}"):
                    self.assertRegex(
                        found.group(1).strip(),
                        r"^(-u|--set-upstream)\b",
                        f"{name}:{number} の git push が upstream を張らない形になっている。"
                        "そのまま打つと落ちるので、読んだ側が各自の形に書き換えることになる (#376)",
                    )


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
