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

import subprocess
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
        ["bash", "-c", f'. "{LIB}"\nis_gh_subcommand "$1" "$2"', "_", command, subcommand],
        capture_output=True,
        text=True,
    )
    return proc.returncode


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


class WiringTest(unittest.TestCase):
    """配線 — 書いただけで guard から使われていなければ効かない。"""

    def test_both_guards_source_the_lib(self):
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertIn("guard-lib.sh", text, f"{name} が共有ヘルパを読んでいない")

    def test_guards_do_not_keep_their_own_copy(self):
        """複製が残っていると、片方だけ直す事故が起きる。"""
        for name in ("agent-comment-guard.sh", "pr-identity-guard.sh"):
            text = (REPO / "scripts" / name).read_text()
            self.assertNotIn("readonly GH=", text, f"{name} に古い正規表現が残っている")


if __name__ == "__main__":
    unittest.main()
