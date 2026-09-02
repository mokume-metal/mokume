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

import os
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

    def test_guards_do_not_extract_the_repo_option_themselves(self):
        """複製が残っていると、片方だけ直す事故が起きる (#128 と同じ理由)。"""
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertNotIn("--repo)", text, f"{name} に自前の -R 抽出が残っている")

    def test_both_guards_pass_the_working_directory(self):
        """cwd を渡さないと、-R が無いコマンドの宛先を決められない (#611)。"""
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertIn(".cwd", text, f"{name} が payload の cwd を読んでいない")

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


if __name__ == "__main__":
    unittest.main()
