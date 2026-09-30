#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/pr-identity-guard.sh の検査 (#103)。

守りたいのは 1 つ — **メンテナ名義で PR を作ろうとしたら、作る前に差し戻される**。
破ると誰も承認できない PR ができ、close して作り直すしかない (ADR-0007 / #88)。

判定はコマンド文字列と GH_TOKEN を見る。例外は最後の差し戻しの直前に push 権限を
1 回引くところ (#184) で、検査ではそこへ gh のスタブを噛ませるので、ネットワークには
出ない。実行は make hooks-test (CI もこれを呼ぶ)。
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

# 判定が読む、打つシェルから継ぐ環境。GH_REPO は宛先に効く (#1729)
TOKEN_ENV = ["GH_TOKEN", "GITHUB_TOKEN", "GH_REPO"]


# gh のスタブ。既定は「何もせず失敗する」— 権限を読めないときは止める側に倒れるので、
# 押し権限の判定を持たない検査はこれまでどおりの結果になる (#184)
FAILING_GH = "#!/bin/bash\nexit 1\n"


def gh_answering_push(value):
    """`gh api repos/<repo> --jq .permissions.push` に value を返すスタブ。"""
    return f"""#!/bin/bash
[ "$1" = api ] || exit 1
echo {value}
"""


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

    gh_script = FAILING_GH

    def stub_dir(self):
        """self.gh_script を gh として置いたディレクトリ (PATH の先頭に置く)。"""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        gh = Path(tmp.name) / "gh"
        gh.write_text(self.gh_script, encoding="utf-8")
        gh.chmod(0o755)
        return tmp.name

    def run_guard(self, command, cwd=None, **env):
        payload = json.dumps(
            {"tool_input": {"command": command}, **({"cwd": cwd} if cwd else {})}
        )
        environment = clean_env(**env)
        environment["PATH"] = f"{self.stub_dir()}:{environment['PATH']}"
        proc = subprocess.run(
            ["/bin/bash", str(GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            env=environment,
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

    # --- PR を作る口は 1 つではない (#719) --------------------------------
    #
    # 綴りの一覧と、載せない口の理由は pr-identity-guard.sh の冒頭にある。
    # ここは「載せる口は差し戻す / 載せない口は素通しする」を 1 件ずつ固定する。

    def test_pr_new_denied(self):
        """gh pr new は gh pr create の組み込みエイリアス。同じものが別の綴りで通っていた。"""
        self.assert_denied('gh pr new --title "x" --body "y"')

    def test_pr_revert_denied(self):
        """revert PR も PR で、author は同じく承認できる集合に入る。"""
        self.assert_denied("gh pr revert 42 --body 'x'")

    def test_the_reason_names_the_port_that_was_typed(self):
        """打っていない綴りで直し方を示すと、読み手が自分の行と突き合わせられない。"""
        reason = self.assert_denied("gh pr new --fill")
        self.assertIn("gh pr new", reason)
        self.assertNotIn("gh pr create", reason)

    def test_dry_run_passes(self):
        """--dry-run は内容を出すだけで PR を作らない。"""
        self.assert_passed("gh pr create --dry-run --fill")

    def test_agent_task_create_passes(self):
        """author が Copilot bot になるので、承認できる集合の外に自動的に居る。"""
        self.assert_passed("gh agent-task create --base main 'なにかする'")

    def test_gh_api_passes(self):
        """任意の綴りで任意の API を叩けるので、ここで数え上げると必ず取りこぼす。
        agent-comment-guard.sh が同じ理由で素通しと宣言している。"""
        self.assert_passed("gh api repos/mokume-metal/mokume/pulls -f title=x")

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

    # --- 前置した gh (#1729) ---------------------------------------------
    #
    # 素通りするとメンテナ名義の PR がそのまま作られる (上の #128 と同じ代償)

    PREFIXES = ("PATH=/tmp/bin:$PATH gh", "/opt/homebrew/bin/gh", "env GH_DEBUG=1 gh")

    def test_prefixed_gh_is_denied_on_every_port(self):
        for gh in self.PREFIXES:
            with self.subTest(gh=gh):
                self.assert_denied(f"{gh} pr create --fill")
                self.assert_denied(f"{gh} pr new --fill")
                self.assert_denied(f"{gh} pr revert 42 --body x")

    def test_personal_token_as_a_prefix_denied(self):
        """前置の代入で個人の token を渡しても、author は人間になる。"""
        self.assert_denied("GH_TOKEN=gho_" + "x" * 36 + " gh pr create --fill")

    def test_prefixed_gh_keeps_the_exceptions(self):
        for gh in self.PREFIXES:
            with self.subTest(gh=gh):
                self.assert_passed(f"{gh} pr view 105")
                self.assert_passed(f"{gh} pr create --dry-run --fill")
                self.assert_passed(f"{gh} pr create --help")
                self.assert_passed(f"{gh} pr create -R other/repo --fill")
                self.assert_passed(
                    'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN'
                    f" && {gh} pr create --fill"
                )

    # --- gh に実際に渡る GH_TOKEN を見る (#1729 の反証) -------------------
    #
    # 前置はその gh にだけ効き、同じ行で発行・export した token より優先される

    SAFE = 'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && git push -u origin HEAD && '

    def test_prefix_that_takes_the_token_away_denied(self):
        for tail in (
            "env -u GH_TOKEN gh pr create --fill",
            "GH_TOKEN= gh pr create --fill",
            "GH_TOKEN=gho_" + "x" * 36 + " gh pr create --fill",
            "env -i PATH=$PATH gh pr create --fill",
            "GH_TOKEN+=x gh pr create --fill",
        ):
            with self.subTest(tail=tail):
                reason = self.assert_denied(self.SAFE + tail)
                self.assertIn("前置", reason)

    def test_token_handed_over_by_the_prefix_passes(self):
        """#1729 の最初の直しが持ち込んだ退行 — 正しく渡す形を的外れな文面で止めた。"""
        self.assert_passed('t="$(bash scripts/gh-app-token.sh)" && GH_TOKEN="$t" gh pr create --fill')
        self.assert_passed('t="$(bash scripts/gh-app-token.sh)" && GH_TOKEN=${t} gh pr new --fill')
        self.assert_passed("GH_TOKEN=ghs_" + "x" * 36 + " gh pr create --fill")

    def test_prefix_token_that_cannot_be_checked_denied(self):
        reason = self.assert_denied('GH_TOKEN="$GH_APP_TOKEN" gh pr create --fill')
        self.assertIn('GH_TOKEN="$t"', reason, "前置で渡す安全な形が案内されていない")
        # 発行が失敗しても伝わらない形 (export 型の文面が当てはまる)
        self.assert_denied('export t="$(bash scripts/gh-app-token.sh)" && GH_TOKEN="$t" gh pr create --fill')

    def test_prefix_that_keeps_the_shell_token_reads_the_statements(self):
        self.assert_passed(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && GH_TOKEN="$GH_TOKEN" gh pr create --fill'
        )
        self.assert_passed('GH_TOKEN="$GH_TOKEN" gh pr create --fill', GH_TOKEN="ghs_" + "x" * 36)

    def test_every_pr_creating_invocation_is_judged(self):
        """先頭の 1 つが通っても、後ろのメンテナ名義の呼び出しは止める。"""
        self.assert_denied("GH_TOKEN=ghs_" + "x" * 36 + " gh pr create --fill && gh pr new --fill")

    def test_issue_and_export_after_gh_do_not_count(self):
        """gh より後ろの発行・export は、その gh に渡らない (#1729 の 2 回目の反証)。"""
        self.assert_denied(
            'gh pr create --fill; GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && true'
        )
        self.assert_denied(
            'GH_TOKEN="$t" gh pr create --fill; t="$(bash scripts/gh-app-token.sh)" && echo'
        )

    def test_statement_that_changes_the_token_before_gh_denied(self):
        self.assert_denied(
            't="$(bash scripts/gh-app-token.sh)" && t=gho_x && GH_TOKEN="$t" gh pr create --fill'
        )
        reason = self.assert_denied(self.SAFE + "unset GH_TOKEN && gh pr create --fill")
        self.assertIn("unset", reason)
        self.assert_denied(self.SAFE + "export GH_TOKEN=gho_x && gh pr create --fill")

    def test_issue_inside_a_subshell_does_not_reach_gh(self):
        self.assert_denied(
            '(GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN) && gh pr create --fill'
        )

    def test_inherited_gh_repo_names_the_destination(self):
        self.assert_denied(
            "gh pr create --fill", cwd=self.other_repo_dir(), GH_REPO="mokume-metal/mokume"
        )
        self.assert_passed("gh pr create --fill", GH_REPO="other/repo")

    # --- 同じコマンドの中で文として変えた宛先と名義 (#1823) ------------

    # PR を作る口 (ガードの PR_CREATING_PORTS)。形 × 口で回す
    PORTS = ("gh pr create --fill", "gh pr new --fill", "gh pr revert 1")

    # 他リポの cwd から、gh より前に宛先を mokume へ変えうる文・前置。{m} は mokume の
    # checkout。形を 1 つ足すなら行を 1 つ足す
    DESTINATION_FORMS = (
        "cd {m} && {gh}",
        "cd {m}; {gh}",
        "cd {m}\n{gh}",
        "pushd {m} && {gh}",
        "(cd {m} && {gh})",
        "export GH_REPO=mokume-metal/mokume && {gh}",
        "GH_REPO=mokume-metal/mokume; export GH_REPO; {gh}",
        "declare -x GH_REPO=mokume-metal/mokume; {gh}",
        "GIT_DIR={m}/.git {gh}",
        "export GIT_DIR={m}/.git && {gh}",
        # 反証 #1〜#3
        "builtin cd {m} && {gh}",
        "command cd {m} && {gh}",
        "builtin export GH_REPO=mokume-metal/mokume && {gh}",
        "GIT_COMMON_DIR={m}/.git {gh}",
        "printf -v GH_REPO %s mokume-metal/mokume && {gh}",
        "read -r GH_REPO <<< mokume-metal/mokume && {gh}",
        # 反証 2 回目の 2-1・2-3・補足の chdir
        "for GH_REPO in mokume-metal/mokume; do {gh}; done",
        "for i in 1 2; do {gh}; cd {m}; done",
        "chdir {m} && {gh}",
    )

    def test_repo_option_that_is_decided_at_run_time_denied(self):
        """反証 2-2 — -R の値が実行時に決まるなら、前置の GH_REPO="$X" と同じく止める側。"""
        for port in self.PORTS:
            with self.subTest(port=port):
                self.assert_denied(f'O=mokume-metal; R=mokume; {port} -R "$O/$R"')
                self.assert_denied(port + ' -R "${REPO:-mokume-metal/mokume}"')
        self.assert_passed('gh pr create --fill -R "other/repo"')

    def test_git_variables_that_do_not_move_the_destination_pass(self):
        """反証 2-5 — 宛先に効かない git の変数は、他リポ宛ての判定を変えない (main の判定)。"""
        there = self.other_repo_dir()
        for command in (
            "GIT_PAGER=cat gh pr create --fill",
            "export GIT_TERMINAL_PROMPT=0 && gh pr create --fill",
            "GIT_SSH_COMMAND=ssh git push && gh pr new --fill",
        ):
            with self.subTest(command=command):
                self.assert_passed(command, cwd=there)

    # mokume の cwd で、継いだ他リポの GH_REPO を消す文 (#1836 の退行)
    UNSET_FORMS = ("unset GH_REPO && {gh}", "export -n GH_REPO && {gh}")

    def test_statement_that_changes_the_destination_denied_on_every_port(self):
        there = self.other_repo_dir()
        for form in self.DESTINATION_FORMS:
            for port in self.PORTS:
                command = form.format(m=REPO, gh=port)
                with self.subTest(command=command):
                    reason = self.assert_denied(command, cwd=there)
                    self.assertIn("-R owner/repo", reason, "逃げ道が案内されていない")
        for form in self.UNSET_FORMS:
            for port in self.PORTS:
                command = form.format(gh=port)
                with self.subTest(command=command):
                    self.assert_denied(command, GH_REPO="other/repo")

    def test_statement_that_changes_the_destination_keeps_the_escape_hatches(self):
        """-R の明示と、mokume 宛ての正しい名義の形は今までどおり通る (#1823 の D)。"""
        there = self.other_repo_dir()
        self.assert_passed(f"cd {REPO} && gh pr create -R other/repo --fill", cwd=there)
        self.assert_passed(
            "export GH_REPO=mokume-metal/mokume && gh pr create -R other/repo --fill", cwd=there
        )
        self.assert_passed(f"gh pr create --fill && cd {REPO}", cwd=there)
        self.assert_passed(f"(cd {REPO} && ls) && gh pr create --fill", cwd=there)
        self.assert_passed(f"cd {REPO} && " + self.SAFE + "gh pr create --fill", cwd=there)

    # 発行から gh までが 1 つの && の並びでない形 (mokume の cwd)。形を 1 つ足すなら行を 1 つ足す
    BROKEN_CHAIN_FORMS = (
        '{issue} && export GH_TOKEN; {gh}',
        '{issue} && export GH_TOKEN\ngit push -u origin HEAD\n{gh}',
        '{issue} && export GH_TOKEN || {gh}',
        'true || {issue} && export GH_TOKEN && {gh}',
        'false && {issue} && export GH_TOKEN && true; {gh}',
        '{issue} && export GH_TOKEN & {gh}',
        't="$(bash scripts/gh-app-token.sh)" && true; GH_TOKEN="$t" {gh}',
        # 反証 #5: 置換の終了コードが発行の失敗を伝えない
        'GH_TOKEN="$(bash scripts/gh-app-token.sh || true)" && export GH_TOKEN && {gh}',
        "GH_TOKEN=\"$(bash scripts/gh-app-token.sh | tr -d '\\n')\" && export GH_TOKEN && {gh}",
        'GH_TOKEN="$(bash scripts/gh-app-token.sh; true)" && export GH_TOKEN && {gh}',
    )

    def test_issue_that_does_not_reach_gh_by_and_denied(self):
        """発行の失敗が gh へ伝わらない形 (#122 の続き・#1823)。文面は && で繋ぐ形を示す。"""
        issue = 'GH_TOKEN="$(bash scripts/gh-app-token.sh)"'
        for form in self.BROKEN_CHAIN_FORMS:
            for port in self.PORTS:
                command = form.format(issue=issue, gh=port)
                with self.subTest(command=command):
                    reason = self.assert_denied(command)
                    self.assertIn("発行が失敗しても後段が走る形", reason)
                    self.assertIn(
                        'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create',
                        reason,
                    )

    def test_issue_that_reaches_gh_by_and_passes(self):
        """1 つの && の並びなら、行を跨いでも・入れ子の中の gh でも通る (#1823 の D の 18)。"""
        self.assert_passed(self.SAFE + "gh pr create --fill")
        self.assert_passed(
            'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN &&\ngh pr create --fill'
        )

    # main で通っていた正しい形 (反証 #7・#8)。パイプラインと複合コマンドは並びの 1 段で、
    # 発行より前の || と、先に済ませた export は発行の失敗の伝わり方を変えない
    REACHING_FORMS = (
        "{safe}printf '%s' body | {gh} --body-file -",
        "{safe}{{ git push -u origin HEAD; {gh}; }}",
        "{safe}if true; then {gh}; fi",
        "git fetch || true && {safe}{gh}",
        'export GH_TOKEN; GH_TOKEN="$(bash scripts/gh-app-token.sh)" && {gh}',
    )

    def test_issue_that_reaches_gh_through_pipes_and_groups_passes(self):
        for form in self.REACHING_FORMS:
            for port in self.PORTS:
                command = form.format(safe=self.SAFE, gh=port)
                with self.subTest(command=command):
                    self.assert_passed(command)

    def test_issue_inside_if_is_still_denied(self):
        """#1823 の D の 19 — 止める側の誤検知のまま (条件の中の発行は && の並びでない)。"""
        self.assert_denied(
            'if GH_TOKEN="$(bash scripts/gh-app-token.sh)"; then export GH_TOKEN; gh pr create --fill; fi'
        )

    # --- 旗と例外は、その gh の呼び出しの中からだけ読む (#1729 の反証) ----

    def test_gh_inside_loops_and_conditions_denied(self):
        self.assert_denied("for b in a b; do gh pr create --fill -H $b; done")
        self.assert_denied("if true; then gh pr create --fill; fi")

    def test_words_of_another_command_do_not_excuse_a_pr(self):
        self.assert_denied("echo --dry-run && gh pr create --fill")
        self.assert_denied("ls --help && gh pr create --fill")
        self.assert_denied("git log -R x/y && gh pr create --fill")

    def test_gh_repo_prefix_names_the_destination(self):
        self.assert_passed("GH_REPO=other/repo gh pr create --fill")
        self.assert_denied("GH_REPO=mokume-metal/mokume gh pr create --fill", cwd=self.other_repo_dir())

    def test_prefixed_mention_in_heredoc_passes(self):
        self.assert_passed(
            "git commit -F - <<'EOF'\n"
            "/opt/homebrew/bin/gh pr create を差し戻すようにした。\n"
            "EOF"
        )

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

    def test_agents_md_keeps_the_search_order(self):
        """AGENTS.md も探す順序を持つ (ADR-0007 決定 5・影響の 1 行目)。

        文面は差し戻しと AGENTS.md の 2 か所に要る — フックはこのリポジトリを主として
        開いた Claude Code にしか効かない。#1372 は AGENTS.md の側を「個人事情」と読んで
        消してしまい、差し戻しの側と違って検査が無かったので素通りした (#184)。
        """
        agents_md = (REPO / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn("自動化から読んでよい秘密の一覧", agents_md)

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


class OutsideCollaboratorTest(GuardTest):
    """push 権限の無い外部の人は止めない (#184)。

    承認者の集合の外に居る人の PR は、どの名義で作っても誰かが承認できる (ADR-0007 の
    不変条件は破れない)。**false と読めたときだけ**通し、それ以外は止める側に倒す。
    """

    COMMAND = "gh pr create -R mokume-metal/mokume --title t --body b"

    def test_push_権限が無いと読めたら素通し(self):
        self.gh_script = gh_answering_push("false")
        self.assert_passed(self.COMMAND)

    def test_push_権限があれば差し戻す(self):
        self.gh_script = gh_answering_push("true")
        self.assert_denied(self.COMMAND)

    def test_権限を読めなければ差し戻す(self):
        self.gh_script = FAILING_GH
        reason = self.assert_denied(self.COMMAND)
        self.assertIn("gh auth status", reason, "読めなかったときの直し方が文面に無い")

    def test_空の答えは差し戻す(self):
        self.gh_script = gh_answering_push("")
        self.assert_denied(self.COMMAND)


class DraftTest(GuardTest):
    """承認が要る PR は Draft で作らせない (#1621)。

    Draft で作った PR には、ルールセットの required_reviewers が maintainers への
    レビュー依頼を出さない。作ってから `gh pr ready --undo` で落とせば依頼は残る
    (#1234 の実測)。そこで重要パスに触れる PR の `--draft` だけを差し戻し、触れない
    PR (多くの描画 PR) の `--draft` は通す — 作ってから落とす形だと、その間だけ描画の
    行列に入ってしまうため。

    判定には手元の差分を使うので、一時の git リポジトリを組んで検査する。origin は
    このリポジトリへ向け、`origin/main` の上に「.github/ を触る枝」と「Sources/ だけの
    枝」を置く。重要パスの一覧は本物のルールセットを読む。
    """

    TOKEN = 'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && '

    def repo(self, *, with_base=True):
        """上の形の使い捨てリポジトリ。with_base=False は origin/main を置かない。"""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "mokume"
        root.mkdir()

        def run(*args):
            subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)

        def commit(path, message):
            file = root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(message, encoding="utf-8")
            run("add", path)
            run("commit", "-q", "-m", message)

        run("init", "-q", "-b", "main")
        # 使い捨てのリポジトリでは署名を切る (#344)
        run("config", "commit.gpgsign", "false")
        run("config", "user.name", "test")
        run("config", "user.email", "test@example.invalid")
        run("remote", "add", "origin", "git@github.com:mokume-metal/mokume.git")
        commit("README.md", "base")
        if with_base:
            run("update-ref", "refs/remotes/origin/main", "HEAD")
        run("switch", "-q", "-c", "code-only")
        commit("Sources/Thing.swift", "code")
        run("switch", "-q", "-c", "touches-github", "main")
        commit(".github/workflows/thing.yml", "ci")
        return root, run

    def protected(self):
        root, _ = self.repo()
        return str(root)

    def unprotected(self):
        root, run = self.repo()
        run("switch", "-q", "code-only")
        return str(root)

    # --- 差し戻すもの ---------------------------------------------------

    def test_重要パスに触れる_PR_を_draft_で作ると差し戻して作り方を案内する(self):
        reason = self.assert_denied(
            self.TOKEN + "gh pr create --draft --title t --body b", cwd=self.protected()
        )
        self.assertIn("gh pr ready --undo", reason, "作ってから落とす形が案内されていない")
        self.assertIn("#1621", reason)

    def test_短い旗_d_も同じ(self):
        self.assert_denied(self.TOKEN + "gh pr create -d --fill", cwd=self.protected())

    def test_pr_new_も同じ(self):
        """create の組み込みエイリアス。口を数え上げた冒頭の表に揃える。"""
        reason = self.assert_denied(self.TOKEN + "gh pr new --draft --fill", cwd=self.protected())
        self.assertIn("gh pr new", reason)

    def test_環境に_installation_token_を置いた経路も同じ(self):
        self.assert_denied(
            "gh pr create --draft --fill", cwd=self.protected(), GH_TOKEN="ghs_" + "x" * 36
        )

    def test_head_で指した枝の差分で判定する(self):
        """手元の HEAD ではなく、PR になる枝を見る。"""
        self.assert_denied(
            self.TOKEN + "gh pr create --draft --head touches-github --fill",
            cwd=self.unprotected(),
        )
        self.assert_passed(
            self.TOKEN + "gh pr create --draft -H code-only --fill", cwd=self.protected()
        )

    def test_前置した_gh_でも旗を読む(self):
        """旗を読む断片の選び方も前置を落とす (#1729)。落とさないと断片が空になり、
        Draft の判定が黙って飛ぶ。"""
        for gh in ("PATH=/tmp/bin:$PATH gh", "/opt/homebrew/bin/gh"):
            with self.subTest(gh=gh):
                self.assert_denied(
                    self.TOKEN + f"{gh} pr create --draft --fill", cwd=self.protected()
                )
                self.assert_passed(
                    self.TOKEN + f"{gh} pr create --draft -H code-only --fill",
                    cwd=self.protected(),
                )

    def test_revert_の_draft_は差分を読めないので差し戻す(self):
        """revert の中身は手元に無い。読めなければ差し戻す側に倒す。"""
        self.assert_denied(self.TOKEN + "gh pr revert 42 --draft", cwd=self.unprotected())

    def elsewhere(self):
        """別のリポジトリの checkout。origin/main の上に重要パスに触れない枝を置く。
        ここの差分は、mokume 宛ての PR の差分ではない。"""
        root, run = self.repo()
        run("remote", "set-url", "origin", "git@github.com:shinyaoguri/setup.git")
        run("switch", "-q", "code-only")
        return str(root)

    def test_cwd_の差分が宛先の差分と確かめられなければ差し戻す(self):
        """反証 #6 — 宛先の判定が cwd を使わなかったなら、Draft の判定も cwd の差分を読まない。

        宛先を「決められない」と読んだ (cd などの文・前置) か、-R / GH_REPO で宛先を名指しした
        とき、cwd の差分はその PR の差分とは限らない。読むと #1621 の穴が開く。
        """
        mokume = self.protected()
        there = self.elsewhere()
        for command in (
            f"cd {mokume} && " + self.TOKEN + "gh pr create --draft --fill",
            self.TOKEN + "GH_REPO=mokume-metal/mokume gh pr create --draft --fill",
            self.TOKEN + "gh pr create -R mokume-metal/mokume --draft --fill",
        ):
            with self.subTest(command=command):
                reason = self.assert_denied(command, cwd=there)
                self.assertIn("gh pr ready --undo", reason)
        # 同じリポジトリの別の checkout (別の worktree) へ cd しても、cwd の差分は読まない
        reason = self.assert_denied(
            f"cd {mokume} && " + self.TOKEN + "gh pr create --draft --fill", cwd=self.unprotected()
        )
        self.assertIn("cwd から変わりうる", reason)
        # 宛先が cwd のリポジトリなら、今までどおり差分で判定する
        self.assert_passed(
            self.TOKEN + "gh pr create -R mokume-metal/mokume --draft --fill",
            cwd=self.unprotected(),
        )
        # 宛先に効かない git の変数の前置では、cwd の差分を読むのをやめない (反証 2-5)
        self.assert_passed(
            self.TOKEN + "GIT_PAGER=cat gh pr create --draft --fill", cwd=self.unprotected()
        )

    def test_差分を読めなければ差し戻して_そう名乗る(self):
        root, _ = self.repo(with_base=False)
        reason = self.assert_denied(
            self.TOKEN + "gh pr create --draft --fill", cwd=str(root)
        )
        self.assertIn("読めなかった", reason)

    # --- 素通しするもの (完了条件 2) -------------------------------------

    def test_重要パスに触れない_PR_の_draft_は通す(self):
        """作ってから落とす形だと、その間だけ描画の行列に入ってしまう。"""
        self.assert_passed(
            self.TOKEN + "gh pr create --draft --title t --body b", cwd=self.unprotected()
        )

    def test_draft_でなければ重要パスに触れても通す(self):
        """作り方は変えない。依頼は required_reviewers の 1 通だけ (#530 を起こさない)。"""
        self.assert_passed(
            self.TOKEN + "gh pr create --title t --body b", cwd=self.protected()
        )

    def test_本文に書いた_draft_は旗ではない(self):
        self.assert_passed(
            self.TOKEN + "gh pr create --fill --body-file - <<'EOF'\n"
            "gh pr create --draft は差し戻される。\n"
            "EOF",
            cwd=self.protected(),
        )


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
