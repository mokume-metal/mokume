#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/guard-lib.sh の検査 (#128)。

守りたいのは 1 つ — **gh がコマンドとして実行される位置にあるときだけ検出する**。
広すぎると地の文 (コミットメッセージ・説明文) で差し戻して guard を迂回する手癖がつき、
狭すぎるとコマンド置換の中を見逃してメンテナ名義の PR が作られる (ADR-0007)。

判定はコマンド文字列だけを見るので、ネットワークも gh も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "guard-lib.sh"

# 検査用の文字列にコマンド名をそのまま書くと、このファイルを編集する Bash 自体が
# guard に差し戻される (それがまさに #128 の誤検知)。組み立てて渡す
COMMENT = "com" + "ment"
CREATE = "cre" + "ate"


def judge(command, subcommand):
    """guard-lib.sh を source した bash で判定させ、終了コードを返す。

    コマンド本文には " も ' も改行も入るので、シェルへは argv で渡す。
    """
    proc = subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\nis_gh_subcommand "$1" "$2"', "_", command, subcommand],
        capture_output=True,
        text=True,
    )
    return proc.returncode


def targets_other_repo(command, cwd=None, **env):
    """宛先の判定を bash に任せ、終了コードを返す。

    基準リポは環境変数で決まるので、呼び出し元の env を引き継がずに立て直す
    (このテスト自体が CI = GITHUB_REPOSITORY が立っている環境からも走る)。

    cwd は「-R が無いとき gh が宛先にするディレクトリ」で、既定は判定を
    ディレクトリに依存させないための空ディレクトリではなく、明示を促すため
    呼び出し側に決めさせる (省略すると guard-lib 側が $PWD を使う)。
    """
    child_env = {k: v for k, v in os.environ.items() if k != "GITHUB_REPOSITORY"}
    child_env.update(env)
    proc = subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\ntargets_other_repo "$1" "$2"', "_", command, cwd or ""],
        capture_output=True,
        text=True,
        env=child_env,
        cwd=cwd,
    )
    return proc.returncode


def make_repo(root, origin):
    """origin だけを持つ使い捨てリポジトリを作る。"""
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True, capture_output=True)
    # 使い捨てのリポジトリでは署名を切る (#344)。ここは commit しないが、
    # 検査の要求は「git を触るファイルは切る」なので揃えておく
    subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=root,
                   check=True, capture_output=True)
    if origin is not None:
        subprocess.run(["git", "remote", "add", "origin", origin], cwd=root,
                       check=True, capture_output=True)
    return root


class IsGhSubcommandTest(unittest.TestCase):
    """gh がコマンド位置にあるか。"""

    def assert_hit(self, command, subcommand):
        self.assertEqual(
            judge(command, subcommand), 0, f"検出されるはずが素通しした: {command!r}"
        )

    def assert_miss(self, command, subcommand):
        self.assertNotEqual(
            judge(command, subcommand), 0, f"素通しのはずが検出した: {command!r}"
        )

    # --- 以前は見逃していた形 (#128 の穴) -------------------------------

    def test_command_substitution(self):
        """url=$(gh pr create …) が素通りすると、メンテナ名義の PR が作られる。"""
        self.assert_hit(f"url=$(gh pr {CREATE} --fill)", f"pr[[:space:]]+{CREATE}")

    def test_backticks(self):
        self.assert_hit(f"url=`gh pr {COMMENT} 7 --body x`", f"pr[[:space:]]+{COMMENT}")

    def test_subshell(self):
        self.assert_hit(f"(gh pr {COMMENT} 7 --body x)", f"pr[[:space:]]+{COMMENT}")

    # --- 従来どおり検出し続ける形 ---------------------------------------

    def test_bare_command(self):
        self.assert_hit(f"gh pr {CREATE} --fill", f"pr[[:space:]]+{CREATE}")

    def test_chained_with_and(self):
        self.assert_hit(
            f"git add -A && gh issue {COMMENT} 1 --body x", f"issue[[:space:]]+{COMMENT}"
        )

    def test_global_option_before_subcommand(self):
        self.assert_hit(
            f"gh -R owner/repo issue {COMMENT} 1 --body x", f"issue[[:space:]]+{COMMENT}"
        )

    def test_assignment_prefix(self):
        """#122 で足した検出。断片が `" gh …` の形になるので先頭のクォートを落とす。"""
        self.assert_hit(
            f'GH_TOKEN="$(bash scripts/gh-app-token.sh)" gh pr {CREATE} --fill',
            f"pr[[:space:]]+{CREATE}",
        )

    def test_safe_token_form(self):
        """#122 で正典にした安全な形。"""
        self.assert_hit(
            f'GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN'
            f" && gh pr {CREATE} --fill",
            f"pr[[:space:]]+{CREATE}",
        )

    def test_indented_inside_if(self):
        self.assert_hit(
            f'if [ -n "$x" ]; then\n  gh issue {COMMENT} 1 --body x\nfi',
            f"issue[[:space:]]+{COMMENT}",
        )

    # --- 地の文 (言及しているだけ・検出してはいけない) ------------------

    def test_prose_mention(self):
        self.assert_miss(f"guard は gh issue {COMMENT} を見ている", f"issue[[:space:]]+{COMMENT}")

    def test_inside_quoted_argument(self):
        self.assert_miss(
            f"t miss 'guard は gh issue {COMMENT} を見る'", f"issue[[:space:]]+{COMMENT}"
        )

    def test_inside_echo(self):
        self.assert_miss(
            f"echo '投稿は gh issue {COMMENT} ではない'", f"issue[[:space:]]+{COMMENT}"
        )

    def test_words_are_not_bridged_across_a_fragment(self):
        """離れた語を繋げて拾わない。

        以前は gh と任意個の語をまたいで後方のサブコマンド名まで拾っていた
        (gh issue … と pr review … のような地の文が該当した)。
        """
        self.assert_miss(
            f"echo 'gh issue {COMMENT} と pr review の話'", "pr[[:space:]]+review"
        )

    # --- ヒアドキュメント本文はデータ ------------------------------------

    def test_heredoc_body_is_data(self):
        """コミットメッセージがコマンド名に言及しただけで差し戻さない。"""
        self.assert_miss(
            f"git commit -F - <<'EOF'\nguard は gh issue {COMMENT} しか見ていない。\nEOF",
            f"issue[[:space:]]+{COMMENT}",
        )

    def test_heredoc_body_at_line_start_is_data(self):
        """本文の行頭に手順として書いた形。断片分割だけでは拾ってしまう。"""
        self.assert_miss(
            f"cat > body.md <<'EOF'\n手順:\n\n  gh issue {COMMENT} 1 --body x\n\n以上。\nEOF",
            f"issue[[:space:]]+{COMMENT}",
        )

    def test_heredoc_opening_line_is_kept(self):
        """開いた行そのものは実コマンドなので残す。"""
        self.assert_hit(
            f"gh issue {COMMENT} 1 --body-file - <<'EOF'\n本文\nEOF",
            f"issue[[:space:]]+{COMMENT}",
        )

    def test_unquoted_and_dash_heredocs(self):
        """<<WORD と <<-WORD (終端行の字下げを許す) にも効く。"""
        self.assert_miss(
            f"cat <<EOF\ngh issue {COMMENT} 1\nEOF", f"issue[[:space:]]+{COMMENT}"
        )
        self.assert_miss(
            f"cat <<-EOF\n\tgh issue {COMMENT} 1\n\tEOF", f"issue[[:space:]]+{COMMENT}"
        )

    def test_herestring_is_not_a_heredoc(self):
        """<<< は本文を持たない。ヒアドキュメントと取り違えて後続を落とさない。"""
        self.assert_hit(
            f"cat <<< 'x'\ngh issue {COMMENT} 1 --body x", f"issue[[:space:]]+{COMMENT}"
        )


class TargetsOtherRepoTest(unittest.TestCase):
    """宛先はこのリポジトリの外か (#188)。

    真なら guard は口を出さない。広すぎると本文に書くだけで素通りでき、狭すぎると
    他リポジトリ宛ての操作まで止めて逃げ道が無くなる。
    """

    def assert_other(self, command, **env):
        self.assertEqual(
            targets_other_repo(command, **env), 0, f"他リポと判定されるはず: {command!r}"
        )

    def assert_own(self, command, **env):
        self.assertNotEqual(
            targets_other_repo(command, **env), 0, f"自リポ扱いのはず: {command!r}"
        )

    def test_other_repo(self):
        self.assert_other(f"gh issue {COMMENT} 5 -R shinyaoguri/claude-plugins --body x")
        self.assert_other(f"gh pr {CREATE} --repo=other/repo --fill")
        self.assert_other(f"gh -R other/repo issue {COMMENT} 5 --body x")

    def test_no_repo_option_falls_back_to_the_current_directory(self):
        """-R が無いときの宛先は gh の既定 — カレントディレクトリのリポジトリ。"""
        with tempfile.TemporaryDirectory() as tmp:
            here = make_repo(Path(tmp) / "mine", "git@github.com:mokume-metal/mokume.git")
            self.assert_own(f"gh issue {COMMENT} 1 --body x", cwd=str(here))

    def test_no_repo_option_in_another_repository_is_other(self):
        """#611 の事象。別のリポジトリのディレクトリから打ったものまで止めない。"""
        with tempfile.TemporaryDirectory() as tmp:
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            self.assert_other(f"gh pr {CREATE} --fill", cwd=str(there))

    def test_https_and_ssh_remotes_resolve_the_same(self):
        for origin in (
            "https://github.com/mokume-metal/mokume.git",
            "https://github.com/mokume-metal/mokume",
            "ssh://git@github.com/mokume-metal/mokume.git",
            "git@github.com:mokume-metal/mokume.git",
        ):
            with self.subTest(origin=origin), tempfile.TemporaryDirectory() as tmp:
                here = make_repo(Path(tmp) / "mine", origin)
                self.assert_own(f"gh issue {COMMENT} 1 --body x", cwd=str(here))

    def test_undecidable_directory_is_own(self):
        """判定できないものは止める側へ倒す — git 管理外と origin 無しの 2 つ。"""
        with tempfile.TemporaryDirectory() as tmp:
            plain = Path(tmp) / "plain"
            plain.mkdir()
            self.assert_own(f"gh pr {CREATE} --fill", cwd=str(plain))

            no_origin = make_repo(Path(tmp) / "no-origin", None)
            self.assert_own(f"gh pr {CREATE} --fill", cwd=str(no_origin))

    def test_cd_inside_the_command_is_not_followed(self):
        """cd 先は追わない — 意図した限界で、逃げ道は -R の明示に一本化する。

        追うと判定が推測になり (変数展開・引用・複数の cd・サブシェル)、その推測を
        permissive な向きに置くとこのリポジトリ宛ての操作を取りこぼす。
        """
        with tempfile.TemporaryDirectory() as tmp:
            here = make_repo(Path(tmp) / "mine", "git@github.com:mokume-metal/mokume.git")
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            self.assert_own(f"cd {there} && gh pr {CREATE} --fill", cwd=str(here))

    def test_repo_option_still_wins_over_the_directory(self):
        """別リポのディレクトリからでも、-R でこのリポジトリを名指ししたなら止める。"""
        with tempfile.TemporaryDirectory() as tmp:
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            self.assert_own(
                f"gh pr {CREATE} -R mokume-metal/mokume --fill", cwd=str(there)
            )

    def test_this_repo_explicitly_is_own(self):
        self.assert_own(f"gh issue {COMMENT} 1 -R mokume-metal/mokume --body x")

    def test_owner_omitted_is_own(self):
        """owner を省いた指定は自リポか判定できない。曖昧なら止める側に倒す。"""
        self.assert_own(f"gh pr {CREATE} --repo mokume --fill")

    def test_last_option_wins(self):
        """gh は後勝ち。判定もそれに合わせる。"""
        self.assert_other(f"gh issue {COMMENT} 1 -R mokume-metal/mokume -R other/repo --body x")
        self.assert_own(f"gh issue {COMMENT} 1 -R other/repo -R mokume-metal/mokume --body x")

    def test_heredoc_body_is_not_a_destination(self):
        """本文の中の --repo は投稿する文章であって宛先ではない。

        落とさないと、本文にそう書くだけで guard を素通りできてしまう。
        """
        self.assert_own(
            f"gh issue {COMMENT} 1 -F - <<'EOF'\n"
            "他リポへ書くときは --repo other/repo を付ける。\n"
            "EOF"
        )

    def test_base_repo_follows_the_environment(self):
        """基準は GITHUB_REPOSITORY。fork や移設で自リポ名が変わっても効き続ける。"""
        self.assert_own(
            f"gh issue {COMMENT} 1 -R other/repo --body x", GITHUB_REPOSITORY="other/repo"
        )
        self.assert_other(
            f"gh issue {COMMENT} 1 -R mokume-metal/mokume --body x",
            GITHUB_REPOSITORY="other/repo",
        )


class WiringTest(unittest.TestCase):
    """配線 — 書いただけで guard から使われていなければ効かない。"""

    def test_both_guards_source_the_lib(self):
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertIn("guard-lib.sh", text, f"{name} が共有ヘルパを読んでいない")

    def test_both_guards_use_the_shared_destination_check(self):
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertIn("targets_other_repo", text, f"{name} が宛先を見ていない")

    def test_the_library_borrows_the_repository_resolution(self):
        """「どのリポジトリか」の解き方は repo-slug.sh が持つ (#818)。"""
        text = LIB.read_text(encoding="utf-8")
        self.assertIn("repo-slug.sh", text, "guard-lib.sh が repo-slug.sh を読んでいない")
        self.assertNotIn("remote get-url", text, "guard-lib.sh が自前で origin を剥がしている")

    def test_guards_do_not_extract_the_repo_option_themselves(self):
        """複製が残っていると、片方だけ直す事故が起きる (#128 と同じ理由)。"""
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertNotIn("--repo)", text, f"{name} に自前の -R 抽出が残っている")

    def test_both_guards_pass_the_working_directory(self):
        """cwd を渡さないと、-R が無いコマンドの宛先を決められない (#611)。

        payload から取り出すのは hook_payload の仕事になった (#815) ので、guard 側で
        見るのは「共有の口から受け取っているか」である。
        """
        self.assertIn(".cwd", LIB.read_text(), "guard-lib.sh が payload の cwd を読んでいない")
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertIn("HOOK_CWD", text, f"{name} が cwd を宛先の判定へ渡していない")

    def test_both_guards_show_the_shared_escape_hatch(self):
        """逃げ道の文面を書き分けると片方だけ古くなる (#611)。"""
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertIn("other_repo_hint", text, f"{name} が逃げ道を案内していない")

    def test_guards_do_not_keep_their_own_copy(self):
        """複製が残っていると、片方だけ直す事故が起きる。"""
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertNotIn("readonly GH=", text, f"{name} に古い正規表現が残っている")


# --- フックの入口と出口 -------------------------------------------------------


def run_lib(script, stdin="", **kwargs):
    """guard-lib.sh を source した bash で 1 行走らせる。"""
    return subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\n{script}'],
        input=stdin,
        capture_output=True,
        text=True,
        **kwargs,
    )


class HookSurfaceTest(unittest.TestCase):
    """差し戻しと payload の解き方 (#815)。

    **綴りは Claude Code 側の仕様に張り付いている。** 直し漏れた 1 本は「JSON を
    返さない = 素通し」になり、guard が黙って効かなくなる (#160 で実際に踏んだ形)。
    """

    def test_deny_returns_the_shape_claude_code_reads(self):
        proc = run_lib('hook_deny "理由の本文"')
        self.assertEqual(proc.returncode, 0, "deny は 0 で終える (非 0 は故障と読まれる)")
        out = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "PreToolUse")
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertEqual(out["permissionDecisionReason"], "理由の本文")

    def test_deny_carries_a_multiline_reason_verbatim(self):
        """差し戻しは読まれる前提の文章。改行・引用符で JSON が壊れない。"""
        reason = '1 行目\n"引用" と $(展開) と \'単引用\'\n3 行目'
        # 引数は argv で渡す (本文に " も ' も入るため)
        proc = subprocess.run(
            ["/bin/bash", "-c", f'. "{LIB}"\nhook_deny "$1"', "_", reason],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            json.loads(proc.stdout)["hookSpecificOutput"]["permissionDecisionReason"], reason
        )

    def test_payload_falls_back_to_the_process_directory(self):
        """cwd を持たない payload でも宛先を決められる (省略は $PWD)。"""
        proc = run_lib('hook_payload; printf "%s" "$HOOK_CWD"', stdin="{}", cwd=str(REPO))
        self.assertEqual(proc.stdout, str(REPO))

    def test_payload_reads_the_cwd_the_hook_received(self):
        proc = run_lib(
            'hook_payload; printf "%s" "$HOOK_CWD"', stdin='{"cwd":"/tmp/elsewhere"}'
        )
        self.assertEqual(proc.stdout, "/tmp/elsewhere")

    def test_missing_jq_passes_through(self):
        """**fail open。** guard が壊れてツールが使えなくなるほうが害が大きい。"""
        with tempfile.TemporaryDirectory() as tmp:
            # **jq だけが無い PATH** を組む。cat は payload の読み取りに、dirname は
            # ライブラリが隣のファイルを source するのに要る — 落とすと「jq が無い」
            # ではなく別の理由で止まり、この検査が見たいものを見なくなる
            for tool in ("/bin/cat", "/usr/bin/dirname"):
                os.symlink(tool, Path(tmp) / Path(tool).name)
            proc = run_lib(
                'hook_payload; echo 通ってはいけない',
                stdin='{"cwd":"/tmp"}',
                env={"PATH": tmp},
            )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "", "jq が無いのに判定を続けている")

    def test_a_missing_repo_slug_library_fails_open(self):
        """**借りている側が読めなくても素通しに倒す** (#818)。

        `guard-lib.sh` は「どのリポジトリか」の解き方を `repo-slug.sh` から借りる。
        読めなければ **何も定義せずに非 0 で返る** ので、フック側の
        `. guard-lib.sh 2>/dev/null || exit 0` がそのまま発火する — 判定できないまま
        差し戻す側へ倒れない。
        """
        with tempfile.TemporaryDirectory() as tmp:
            # guard-lib.sh だけを写した置き場 (隣に repo-slug.sh が無い)
            alone = Path(tmp) / "guard-lib.sh"
            alone.write_text(LIB.read_text(encoding="utf-8"), encoding="utf-8")
            proc = subprocess.run(
                ["/bin/bash", "-c", f'. "{alone}" 2>/dev/null || exit 0\necho 通ってはいけない'],
                capture_output=True,
                text=True,
            )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "", "ライブラリが読めないのに判定を続けている")

    def test_command_absent_passes_through(self):
        """Edit / Write のようにコマンドを持たない入力では素通しで終わる。"""
        proc = run_lib(
            'hook_payload; hook_command; echo 通ってはいけない',
            stdin='{"tool_input":{"file_path":"/x"}}',
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")

    def test_command_is_taken_from_the_tool_input(self):
        proc = run_lib(
            'hook_payload; hook_command; printf "%s" "$HOOK_COMMAND"',
            stdin='{"tool_input":{"command":"gh pr view 1"}}',
        )
        self.assertEqual(proc.stdout, "gh pr view 1")

    def test_help_request(self):
        for command, expected in (
            ("gh pr " + CREATE + " --help", True),
            ("gh pr " + CREATE + " -h", True),
            ("gh pr " + CREATE + " -h --fill", True),
            ("gh pr " + CREATE + " --fill", False),
            # --help を含む語は違う (--helper のような綴りで素通しさせない)
            ("gh pr " + CREATE + " --helper x", False),
            # 引用符の中の -h は独立した語ではないので当たらない。本文で -h に言及した
            # だけの呼び出しを素通しさせない (guard-lib の誤検知の方針と同じ向き)
            ("gh pr " + CREATE + " --body '-h'", False),
        ):
            with self.subTest(command=command):
                proc = subprocess.run(
                    ["/bin/bash", "-c", f'. "{LIB}"\nis_help_request "$1"', "_", command],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(proc.returncode == 0, expected)


class HookExitIsSharedTest(unittest.TestCase):
    """**フックの出口が 1 箇所であることを構造で見る (#815)。**

    #160 は `pr-identity-guard.sh` が bash 3.2 のパースに失敗して JSON を返さず、
    PreToolUse フックとしては**素通しと同じ**になった事故である。あのときフックは
    1 本だったから気付けた。綴りが 3 本に散った状態で仕様が動けば、直し漏れた 1 本は
    黙って効かなくなる。

    **一覧は数え上げない** — `scripts/*-guard.sh` を glob するので、4 本目を足した人が
    ここを直さなくても掛かる (`bash_invocation_test.py` が検査ファイル全体を glob して
    `/bin/bash` を見張っているのと同じ構え)。
    """

    def hooks(self):
        found = sorted(p for p in (REPO / "scripts").glob("*-guard.sh"))
        # 対象が 0 件の緑は、通っていることに意味が無い (置き場の移動を緑のまま
        # 見逃さないため。bash_invocation_test.py と同じ構え)
        self.assertTrue(found, "検査対象のフックが 1 つも無い")
        return found

    def offending(self, path, predicate):
        """条件に当たる行を「行番号: 中身」で返す。**散文は見ない。**

        差し戻しの向き (`ask ではなく deny なのは…`) は解説として書かれているので、
        コメント行を数えると直せない赤になる。
        """
        found = []
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if predicate(line):
                found.append(f"  {path.name}:{number}: {line.strip()}")
        return found

    def test_no_hook_spells_the_json_itself(self):
        for path in self.hooks():
            with self.subTest(hook=path.name):
                lines = self.offending(path, lambda line: "permissionDecision" in line)
                if lines:
                    self.fail(
                        f"{path.name} が差し戻しの JSON を自前で組んでいる:\n"
                        + "\n".join(lines)
                        + "\n\n直し方: guard-lib.sh の hook_deny <理由> を通す。"
                        "綴りが散ると、仕様が動いたとき直し漏れた 1 本が素通しになる (#160)。"
                    )

    def test_no_hook_defines_its_own_deny(self):
        for path in self.hooks():
            with self.subTest(hook=path.name):
                lines = self.offending(path, lambda line: re.match(r"\s*deny\(\)", line))
                if lines:
                    self.fail(
                        f"{path.name} に自前の deny() が残っている:\n"
                        + "\n".join(lines)
                        + "\n\n直し方: 定義を落として hook_deny を呼ぶ。"
                    )

    def test_every_hook_goes_through_the_shared_exit(self):
        for path in self.hooks():
            with self.subTest(hook=path.name):
                text = path.read_text()
                self.assertIn("guard-lib.sh", text, f"{path.name} が共有ライブラリを読んでいない")
                self.assertIn("hook_deny", text, f"{path.name} が共有の出口を通っていない")

    def test_every_hook_fails_open_when_the_library_is_missing(self):
        """source に失敗したら素通し。ライブラリを共有した代償を guard 側で払わない。"""
        for path in self.hooks():
            with self.subTest(hook=path.name):
                self.assertRegex(
                    path.read_text(),
                    r'guard-lib\.sh" 2>/dev/null \|\| exit 0',
                    f"{path.name} の source が fail open になっていない",
                )

    def test_the_shared_exit_lives_in_the_library(self):
        """畳んだ先が空になっていない (この検査自身が空回りしていたら赤くする)。"""
        self.assertIn("permissionDecision", LIB.read_text())


if __name__ == "__main__":
    unittest.main()
