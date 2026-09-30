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
import resource
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


def judge(command, subcommand, body=None):
    """guard-lib.sh を source した bash で判定させ、終了コードを返す。

    コマンド本文には " も ' も改行も入るので、シェルへは argv で渡す。body を渡さなければ
    フックと同じ形 (ANY_INVOCATION_IS) で読む。
    """
    proc = subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\n{body or ANY_INVOCATION_IS}', "_", command, subcommand],
        capture_output=True,
        text=True,
    )
    return proc.returncode


# フックと同じ形で読む — gh の呼び出しごとに、その断片がサブコマンドか (#1729)
ANY_INVOCATION_IS = """
while IFS=$'\\t' read -r token repo chdir place fragment; do
  gh_fragment_is "$fragment" "$2" && exit 0
done < <(gh_invocations "$1")
exit 1
"""

# 呼び出しが 1 つ以上あり、どれも他リポ宛てか
EVERY_INVOCATION_IS_OTHER = """
cwd=${2:-$PWD}
any=1
while IFS=$'\\t' read -r token repo chdir place fragment; do
  any=0
  invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$cwd" || exit 1
done < <(gh_invocations "$1")
exit "$any"
"""


def targets_other_repo(command, cwd=None, **env):
    """宛先の判定を bash に任せ、終了コードを返す。

    基準リポは環境変数で決まるので、呼び出し元の env を引き継がずに立て直す
    (このテスト自体が CI = GITHUB_REPOSITORY が立っている環境からも走る)。

    cwd は「-R が無いとき gh が宛先にするディレクトリ」で、既定は判定を
    ディレクトリに依存させないための空ディレクトリではなく、明示を促すため
    呼び出し側に決めさせる (省略すると guard-lib 側が $PWD を使う)。
    """
    child_env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_REPOSITORY", "GH_REPO")}
    child_env.update(env)
    proc = subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\n{EVERY_INVOCATION_IS_OTHER}', "_", command, cwd or ""],
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

    # --- 前置した gh (#1729) ---------------------------------------------
    #
    # gh はコマンドとして実行される位置にあるのに、先頭語の綴りが gh でないという
    # 理由で落ちていた形。上の GH_TOKEN="$(…)" は $( と ) で割れた残りが `" gh …` に
    # なるので偶然拾えていたが、コマンド置換を含まない代入では拾えなかった

    def test_plain_assignment_prefix(self):
        self.assert_hit(
            f"PATH=/tmp/bin:$PATH gh issue {COMMENT} 1 --body x", f"issue[[:space:]]+{COMMENT}"
        )
        self.assert_hit(f"GH_TOKEN=x gh pr {CREATE} --fill", f"pr[[:space:]]+{CREATE}")

    def test_several_and_quoted_assignments(self):
        self.assert_hit(
            f"A=1 B=\"x y\" C='z w' D= gh pr {CREATE} --fill", f"pr[[:space:]]+{CREATE}"
        )
        self.assert_hit(
            f'GH_TOKEN="$(cat t)" PATH=/tmp/bin:$PATH gh pr {CREATE} --fill',
            f"pr[[:space:]]+{CREATE}",
        )

    def test_assignment_prefix_after_an_operator(self):
        self.assert_hit(
            f"git add -A && PATH=/tmp/bin:$PATH gh issue {COMMENT} 1 --body x",
            f"issue[[:space:]]+{COMMENT}",
        )
        self.assert_hit(
            f"url=$(PATH=/tmp/bin gh pr {CREATE} --fill)", f"pr[[:space:]]+{CREATE}"
        )

    def test_env_prefix(self):
        """env も代入を前置する形。冒頭で許容していた取りこぼし (env X=1 gh) を塞ぐ。"""
        self.assert_hit(f"env X=1 gh issue {COMMENT} 1 --body x", f"issue[[:space:]]+{COMMENT}")
        self.assert_hit(
            f"/usr/bin/env -i PATH=/tmp/bin gh pr {CREATE} --fill", f"pr[[:space:]]+{CREATE}"
        )
        self.assert_hit(f"env -u GH_TOKEN gh pr {CREATE} --fill", f"pr[[:space:]]+{CREATE}")
        self.assert_hit(f"env gh pr {CREATE} --fill", f"pr[[:space:]]+{CREATE}")

    def test_gh_called_by_path(self):
        for gh in ("/tmp/bin/gh", "/opt/homebrew/bin/gh", "./gh", "~/bin/gh", '"$HOME/bin/gh"'):
            with self.subTest(gh=gh):
                self.assert_hit(f"{gh} issue {COMMENT} 1 --body x", f"issue[[:space:]]+{COMMENT}")
        self.assert_hit(
            f"PATH=/tmp/bin:$PATH /tmp/bin/gh -R owner/repo pr {CREATE} --fill",
            f"pr[[:space:]]+{CREATE}",
        )

    def test_prefix_does_not_widen_what_counts_as_gh(self):
        """前置を落とすのは先頭だけ。別のコマンドの引数や、gh でない名前は拾わない。"""
        for command in (
            f"X=1 echo 'gh issue {COMMENT} 1'",
            f"echo PATH=/tmp/bin gh issue {COMMENT} 1",
            f"ls /tmp/bin/gh issue {COMMENT}",
            f"/tmp/bin/ghx issue {COMMENT} 1",
            f"/tmp/bin/gh-wrapper issue {COMMENT} 1",
            f"git commit -m 'PATH=/tmp/bin gh issue {COMMENT} を拾う'",
            f"cat <<'EOF'\nPATH=/tmp/bin gh issue {COMMENT} 1\n/tmp/bin/gh issue {COMMENT} 1\nEOF",
        ):
            with self.subTest(command=command):
                self.assert_miss(command, f"issue[[:space:]]+{COMMENT}")

    # --- 実行位置を字句で読む (#1729 の反証) -----------------------------
    #
    # 以前は演算子の文字で素朴に割って先頭語を見ていたので、割った後の先頭が予約語・
    # リダイレクトになる形と、行継続・引用した gh を取りこぼし、引用の中まで ; で割った

    def test_reserved_words_before_gh(self):
        for command in (
            f"for i in 1 2; do gh issue {COMMENT} $i --body x; done",
            f"if true; then gh issue {COMMENT} 1 --body x; fi",
            f"if gh issue {COMMENT} 1 --body x; then :; fi",
            f"if false; then :; elif true; then :; else gh issue {COMMENT} 1 --body x; fi",
            f"until false; do gh issue {COMMENT} 1 --body x; done",
            f"while true; do gh issue {COMMENT} 1 --body x; done",
            f"true || {{ gh issue {COMMENT} 1 --body x; }}",
            f"! gh issue {COMMENT} 1 --body x",
            f"time -p gh issue {COMMENT} 1 --body x",
            f"case $x in a) gh issue {COMMENT} 1 --body x;; esac",
        ):
            with self.subTest(command=command):
                self.assert_hit(command, f"issue[[:space:]]+{COMMENT}")

    def test_redirections_and_other_prefixes(self):
        for command in (
            f"2>/dev/null gh issue {COMMENT} 1 --body x",
            f">/tmp/o gh issue {COMMENT} 1 --body x",
            f"> /tmp/o gh issue {COMMENT} 1 --body x",
            f"&>/tmp/o gh issue {COMMENT} 1 --body x",
            f"gh issue {COMMENT} 1 --body x 2>&1 | tee log",
            f"A+=x gh issue {COMMENT} 1 --body x",
            f"A[1]=x gh issue {COMMENT} 1 --body x",
            f"A=x\\ y gh issue {COMMENT} 1 --body x",
            f'A="a\\"b" gh issue {COMMENT} 1 --body x',
            f"env -P /tmp/bin gh issue {COMMENT} 1 --body x",
            f"env -C /tmp gh issue {COMMENT} 1 --body x",
            f"env -iv -u X gh issue {COMMENT} 1 --body x",
            f"env -S 'gh issue {COMMENT} 1 --body x'",
            f"env -- gh issue {COMMENT} 1 --body x",
        ):
            with self.subTest(command=command):
                self.assert_hit(command, f"issue[[:space:]]+{COMMENT}")

    def test_line_continuation(self):
        for command in (
            f"gh \\\n  issue {COMMENT} 1 --body x",
            f"/tmp/bin/gh \\\n  issue {COMMENT} 1 --body x",
            f"A=1 \\\n  gh issue {COMMENT} 1 --body x",
            f"env A=1 \\\n  gh issue {COMMENT} 1 --body x",
        ):
            with self.subTest(command=command):
                self.assert_hit(command, f"issue[[:space:]]+{COMMENT}")

    def test_quoted_or_escaped_gh(self):
        for command in (
            f'"gh" issue {COMMENT} 1 --body x',
            f"A=1 'gh' issue {COMMENT} 1 --body x",
            f"\\gh issue {COMMENT} 1 --body x",
            f"'/tmp/b in/gh' issue {COMMENT} 1 --body x",
            f'"/tmp/b in/gh" issue {COMMENT} 1 --body x',
        ):
            with self.subTest(command=command):
                self.assert_hit(command, f"issue[[:space:]]+{COMMENT}")

    def test_inside_double_quotes_the_substitution_is_still_a_command(self):
        self.assert_hit(f'echo "url: $(gh pr {CREATE} --fill)"', f"pr[[:space:]]+{CREATE}")
        self.assert_hit(f'echo "url: `gh pr {CREATE} --fill`"', f"pr[[:space:]]+{CREATE}")
        self.assert_hit(f"diff <(gh pr {CREATE} --fill) x", f"pr[[:space:]]+{CREATE}")

    def test_quotes_and_comments_are_not_split(self):
        """引用の中の ; と、語の頭の # からの注釈は、コマンドの区切りではない。"""
        for command in (
            f'git commit -m "note; gh issue {COMMENT} 1"',
            f'git commit -m "note; X=1 gh issue {COMMENT} 1"',
            f'git commit -m "note; /opt/homebrew/bin/gh issue {COMMENT} 1"',
            f"echo 'a && gh issue {COMMENT} 1'",
            f"echo $'a; gh issue {COMMENT} 1'",
            f'git commit -m "line 1\nline 2; gh issue {COMMENT} 1"',
            f"echo x # ; gh issue {COMMENT} 1",
            f"# gh issue {COMMENT} 1",
        ):
            with self.subTest(command=command):
                self.assert_miss(command, f"issue[[:space:]]+{COMMENT}")

    def test_japanese_text_does_not_stop_the_reader(self):
        """macOS の awk は UTF-8 のまま 1 文字ずつ切ると止まり、止まると素通しになる。"""
        self.assert_hit(f'gh issue {COMMENT} 1 --body "日本語の本文"', f"issue[[:space:]]+{COMMENT}")
        self.assert_hit(f'echo "件名" && gh issue {COMMENT} 1 --body x', f"issue[[:space:]]+{COMMENT}")

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
        """cd 先は追わない。追わずに「宛先を決められない」として止める側へ倒す (#1823)。

        追うと判定が推測になり (変数展開・引用・複数の cd・サブシェル)、その推測を
        permissive な向きに置くとこのリポジトリ宛ての操作を取りこぼす。以前は追わない
        まま cwd で決めていたので、別のリポジトリの cwd から `cd <mokume> && gh …` を
        打つと素通りした。逃げ道は -R の明示に一本化する。
        """
        with tempfile.TemporaryDirectory() as tmp:
            here = make_repo(Path(tmp) / "mine", "git@github.com:mokume-metal/mokume.git")
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            self.assert_own(f"cd {there} && gh pr {CREATE} --fill", cwd=str(here))
            self.assert_own(f"cd {here} && gh pr {CREATE} --fill", cwd=str(there))
            self.assert_other(f"cd {here} && gh pr {CREATE} -R other/repo --fill", cwd=str(there))

    def test_statements_that_change_the_destination_make_it_undecidable(self):
        """gh より前の文・前置で宛先が変わりうるなら、決められないとして止める側 (#1823)。

        対照 (#1823 の「再現」の D) も同じ表で持つ。形を 1 つ足すなら行を 1 つ足す。
        {m} は mokume の checkout、{o} は別のリポジトリの checkout。
        """
        with tempfile.TemporaryDirectory() as tmp:
            here = make_repo(Path(tmp) / "mine", "git@github.com:mokume-metal/mokume.git")
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            gh = f"gh pr {CREATE} --fill"
            cases = (
                # (cwd, 継ぐ GH_REPO, 打つもの, 他リポと判定するか)
                # A: 他リポの cwd から、宛先を mokume へ変えうる文・前置 → 止める側
                (there, None, "cd {m} && {gh}", False),
                (there, None, "cd {m}; {gh}", False),
                (there, None, "cd {m}\n{gh}", False),
                (there, None, "pushd {m} && {gh}", False),
                (there, None, "popd; {gh}", False),
                (there, None, "(cd {m} && {gh})", False),
                # 入れ子は外の文を継ぐ
                (there, None, "cd {m} && ({gh})", False),
                (there, None, "cd {m} && url=$({gh})", False),
                (there, None, "export GH_REPO=mokume-metal/mokume && echo \"`{gh}`\"", False),
                (there, None, "if cd {m}; then {gh}; fi", False),
                (there, None, "export GH_REPO=mokume-metal/mokume && {gh}", False),
                (there, None, "GH_REPO=mokume-metal/mokume; export GH_REPO; {gh}", False),
                (there, None, "declare -x GH_REPO=mokume-metal/mokume; {gh}", False),
                (there, None, "typeset -x GH_REPO=mokume-metal/mokume; {gh}", False),
                (there, None, "GIT_DIR={m}/.git {gh}", False),
                (there, None, "env GIT_DIR={m}/.git {gh}", False),
                (there, None, "export GIT_DIR={m}/.git && {gh}", False),
                # B: mokume の cwd で、継いだ他リポの GH_REPO を消す文 → 止める側
                (here, "other/repo", "unset GH_REPO && {gh}", False),
                (here, "other/repo", "export -n GH_REPO && {gh}", False),
                # D: いまの判定を保つ
                (there, None, "env -C {m} {gh}", False),
                (there, None, "GH_REPO=mokume-metal/mokume {gh}", False),
                (here, "other/repo", "env -u GH_REPO {gh}", False),
                (here, None, "cd {o} && {gh}", False),
                (here, None, "export GH_REPO=other/repo && {gh}", False),
                (there, None, "{gh}", True),
                (there, None, "export GH_REPO=mokume-metal/mokume && {gh} -R other/repo", True),
                (there, None, "cd {m} && {gh} -R other/repo", True),
                (there, None, "GH_REPO=other/repo; export GH_REPO; GH_REPO=other/repo {gh}", True),
                (there, None, "{gh} && cd {m}", True),
                # 入れ子の中の cd は gh に効かないので、cwd のまま読む
                (there, None, "x=$(cd {m} && pwd) && {gh}", True),
                (there, None, "(cd {m} && ls) && {gh}", True),
                (there, None, "echo cd {m} && {gh}", True),
            )
            for cwd, inherited, form, other in cases:
                command = form.format(m=here, o=there, gh=gh)
                env = {"GH_REPO": inherited} if inherited else {}
                with self.subTest(command=command, cwd=cwd.name, GH_REPO=inherited):
                    got = targets_other_repo(command, cwd=str(cwd), **env) == 0
                    self.assertEqual(got, other)

    def test_prefixed_gh_keeps_the_repo_option(self):
        """前置した gh でも、-R の宛先の読み方は変わらない (#1729)。"""
        self.assert_other(f"PATH=/tmp/bin:$PATH gh issue {COMMENT} 5 -R other/repo --body x")
        self.assert_other(f"/tmp/bin/gh pr {CREATE} --repo=other/repo --fill")

    def test_gh_repo_prefix_is_the_destination(self):
        """前置の GH_REPO= はその gh にだけ渡る値で、推測にならないので読む (#1729)。

        読まずにいると止める側へ片方向にしか倒れず、別のリポジトリの cwd から
        mokume を名指しした形を素通しにしていた (反証役の指摘)。
        """
        with tempfile.TemporaryDirectory() as tmp:
            here = make_repo(Path(tmp) / "mine", "git@github.com:mokume-metal/mokume.git")
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            self.assert_other(f"GH_REPO=other/repo gh pr {CREATE} --fill", cwd=str(here))
            self.assert_own(f"GH_REPO=mokume-metal/mokume gh pr {CREATE} --fill", cwd=str(there))
            # -R が前置より勝つ (gh と同じ順)
            self.assert_own(
                f"GH_REPO=other/repo gh pr {CREATE} -R mokume-metal/mokume --fill", cwd=str(there)
            )
            # 値を読めない・cwd から決められないものは止める側
            self.assert_own(f'GH_REPO="$R" gh pr {CREATE} --fill', cwd=str(there))
            self.assert_own(f"env -C {here} gh pr {CREATE} --fill", cwd=str(there))
            # env -u GH_REPO は cwd に戻す
            self.assert_other(f"env -u GH_REPO gh pr {CREATE} --fill", cwd=str(there))

    def test_inherited_gh_repo_is_the_destination(self):
        """打つシェルから継いだ GH_REPO も宛先 (GH_TOKEN を継ぐのと同じ・#1729 の 2 回目の反証)。"""
        with tempfile.TemporaryDirectory() as tmp:
            here = make_repo(Path(tmp) / "mine", "git@github.com:mokume-metal/mokume.git")
            there = make_repo(Path(tmp) / "theirs", "git@github.com:shinyaoguri/setup.git")
            self.assert_own(
                f"gh issue {COMMENT} 1 -b x", cwd=str(there), GH_REPO="mokume-metal/mokume"
            )
            self.assert_other(f"gh pr {CREATE} --fill", cwd=str(here), GH_REPO="other/repo")
            # 前置と -R は継いだものより勝つ。env -u GH_REPO は cwd に戻す
            self.assert_other(
                f"GH_REPO=other/repo gh pr {CREATE} --fill", cwd=str(here), GH_REPO="mokume-metal/mokume"
            )
            self.assert_other(
                f"env -u GH_REPO gh pr {CREATE} --fill", cwd=str(there), GH_REPO="mokume-metal/mokume"
            )

    def test_repo_option_of_another_command_is_not_the_destination(self):
        """同じ行の別のコマンドの -R は、gh の宛先ではない (#1729 の反証)。"""
        self.assert_own(f"git log -R x/y && gh pr {CREATE} --fill")
        self.assert_own(f"git diff -R foo/bar; gh issue {COMMENT} 1 --body x")

    def test_every_invocation_must_target_another_repo(self):
        """1 つでもこのリポジトリ宛ての呼び出しがあれば、コマンド全体は外宛てではない。"""
        self.assert_own(f"gh pr view -R other/repo 1 && gh pr {CREATE} --fill")

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


def invocations(command, **env):
    """gh_invocations の行を (GH_TOKEN, GH_REPO, chdir, 置き場, 断片) の組で返す。"""
    proc = subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\ngh_invocations "$1"', "_", command],
        capture_output=True,
        text=True,
        env={**os.environ, **env},
    )
    assert proc.returncode == 0 and not proc.stderr, proc.stderr
    return [tuple(line.split("\t", 4)) for line in proc.stdout.splitlines()]


ISSUE = 'GH_TOKEN="$(bash scripts/gh-app-token.sh)"'


class GhInvocationsTest(unittest.TestCase):
    """gh の呼び出しごとに、その gh に渡る環境を読む (#1729 の反証)。

    名義と宛先の判定は、前置 (GH_TOKEN= / GH_REPO= / env -u / env -i) と、**gh より前に
    置いた**文 (発行・export・unset・再代入) だけから決まる。コマンド全体への部分一致だと、
    gh の後ろに書いた発行まで「渡した」と読む。
    """

    def token_of(self, command):
        rows = invocations(command)
        self.assertEqual(len(rows), 1, rows)
        return rows[0][0]

    def test_no_prefix_inherits(self):
        self.assertEqual(self.token_of(f"gh pr {CREATE} --fill"), "inherit")
        self.assertEqual(self.token_of(f"PATH=/x gh pr {CREATE} --fill"), "inherit")

    def test_safe_issue_and_export_before_gh(self):
        self.assertEqual(
            self.token_of(f"{ISSUE} && export GH_TOKEN && git push && gh pr {CREATE} --fill"),
            "installation",
        )
        self.assertEqual(self.token_of(f"{ISSUE} && gh pr {CREATE} --fill"), "unexported")
        self.assertEqual(self.token_of(f"{ISSUE}; export GH_TOKEN; gh pr {CREATE} --fill"), "unsafe")
        self.assertEqual(
            self.token_of(f'export GH_TOKEN="$(bash scripts/gh-app-token.sh)" && gh pr {CREATE} --fill'),
            "unsafe",
        )

    def test_issue_export_and_gh_must_be_one_and_list(self):
        """発行から gh までが 1 つの && の並びでなければ、発行の失敗が gh へ伝わらない (#1823)。

        #122 が塞いだ形 (発行の直後が && でない) の続きで、見ていたのは発行の直後の区切り
        だけだった。形を 1 つ足すなら行を 1 つ足す。
        """
        t = 't="$(bash scripts/gh-app-token.sh)"'
        gh = f"gh pr {CREATE} --fill"
        for command, expected in (
            # 並びが崩れている → unsafe
            (f"{ISSUE} && export GH_TOKEN; {gh}", "unsafe"),
            (f"{ISSUE} && export GH_TOKEN\ngit push -u origin HEAD\n{gh}", "unsafe"),
            (f"{ISSUE} && export GH_TOKEN || {gh}", "unsafe"),
            (f"{ISSUE} && export GH_TOKEN && true || {gh}", "unsafe"),
            (f"true || {ISSUE} && export GH_TOKEN && {gh}", "unsafe"),
            (f"false && {ISSUE} && export GH_TOKEN && true; {gh}", "unsafe"),
            (f"{ISSUE} && export GH_TOKEN & {gh}", "unsafe"),
            (f"{ISSUE} && export GH_TOKEN && echo | {gh}", "unsafe"),
            (f"{ISSUE} && export GH_TOKEN && (true); {gh}", "unsafe"),
            (f"{ISSUE}; export GH_TOKEN && {gh}", "unsafe"),
            (f"{t} && true; GH_TOKEN=\"$t\" {gh}", "unsafe"),
            (f"true || {t} && GH_TOKEN=\"$t\" {gh}", "unsafe"),
            (f"{t} && GH_TOKEN=$t; export GH_TOKEN && {gh}", "unsafe"),
            # 1 つの && の並び → installation
            (f"{ISSUE} && export GH_TOKEN && git push -u origin HEAD && {gh}", "installation"),
            (f"{ISSUE} && export GH_TOKEN &&\n{gh}", "installation"),
            (f"{ISSUE} && export GH_TOKEN && (true) && {gh}", "installation"),
            (f"cd /tmp && {ISSUE} && export GH_TOKEN && {gh}", "installation"),
            (f"echo start; {ISSUE} && export GH_TOKEN && {gh}", "installation"),
            (f"{ISSUE} && export GH_TOKEN && url=$({gh})", "installation"),
            (f"{t} && GH_TOKEN=\"$t\" {gh}", "installation"),
            (f"{t} && GH_TOKEN=$t && export GH_TOKEN && {gh}", "installation"),
            # 直書きの ghs_ は発行が失敗しえないので、並びを問わない
            (f"GH_TOKEN=ghs_x; export GH_TOKEN; {gh}", "installation"),
        ):
            with self.subTest(command=command):
                self.assertEqual(self.token_of(command), expected)

    def test_statements_after_gh_do_not_count(self):
        """#1729 の 2 回目の反証 — 発行と export が gh の後ろにある。"""
        self.assertEqual(
            self.token_of(f"gh pr {CREATE} --fill; {ISSUE} && export GH_TOKEN && true"), "inherit"
        )
        self.assertEqual(
            self.token_of(f'GH_TOKEN="$t" gh pr {CREATE} --fill; t="$(bash scripts/gh-app-token.sh)" && echo'),
            "other",
        )

    def test_statements_that_change_the_token_before_gh(self):
        self.assertEqual(
            self.token_of(f't="$(bash scripts/gh-app-token.sh)" && t=gho_x && GH_TOKEN="$t" gh pr {CREATE} --fill'),
            "other",
        )
        self.assertEqual(
            self.token_of(f"{ISSUE} && export GH_TOKEN && unset GH_TOKEN && gh pr {CREATE} --fill"),
            "removed",
        )
        self.assertEqual(
            self.token_of(f"{ISSUE} && export GH_TOKEN && export GH_TOKEN=gho_x && gh pr {CREATE} --fill"),
            "other",
        )

    def test_statements_inside_a_subshell_do_not_leak(self):
        self.assertEqual(
            self.token_of(f"({ISSUE} && export GH_TOKEN) && gh pr {CREATE} --fill"), "inherit"
        )

    def test_prefix_sets_the_token(self):
        self.assertEqual(self.token_of(f"GH_TOKEN=ghs_x gh pr {CREATE} --fill"), "installation")
        self.assertEqual(
            self.token_of(f't="$(bash scripts/gh-app-token.sh)" && GH_TOKEN="$t" gh pr {CREATE} --fill'),
            "installation",
        )
        self.assertEqual(self.token_of(f"{ISSUE} gh pr {CREATE} --fill"), "unsafe")
        self.assertEqual(self.token_of(f"GH_TOKEN= gh pr {CREATE} --fill"), "other")
        self.assertEqual(self.token_of(f'GH_TOKEN="$X" gh pr {CREATE} --fill'), "other")
        self.assertEqual(self.token_of(f'GH_TOKEN="$GH_TOKEN" gh pr {CREATE} --fill'), "inherit")
        self.assertEqual(self.token_of(f"env GH_TOKEN=gho_x gh pr {CREATE} --fill"), "other")

    def test_env_removes_the_token(self):
        for command in (
            f"env -u GH_TOKEN gh pr {CREATE} --fill",
            f"env -uGH_TOKEN gh pr {CREATE} --fill",
            f"env --unset=GH_TOKEN gh pr {CREATE} --fill",
            f"env -i PATH=/x gh pr {CREATE} --fill",
            f"env - PATH=/x gh pr {CREATE} --fill",
            f"{ISSUE} && export GH_TOKEN && env -u GH_TOKEN gh pr {CREATE} --fill",
        ):
            with self.subTest(command=command):
                self.assertEqual(self.token_of(command), "removed")
        # 消した後に渡し直せば、その値
        self.assertEqual(self.token_of(f"env -i GH_TOKEN=ghs_x gh pr {CREATE} --fill"), "installation")

    def test_unreadable_change_is_marked(self):
        self.assertEqual(self.token_of(f"GH_TOKEN+=x gh pr {CREATE} --fill"), "unknown")

    def test_each_invocation_carries_its_own_prefix(self):
        rows = invocations(f"GH_TOKEN=ghs_x gh pr view 1 && gh pr {CREATE} --fill")
        self.assertEqual([r[0] for r in rows], ["installation", "inherit"])

    def test_chdir_and_place_are_marked(self):
        self.assertEqual(invocations(f"env -C /tmp gh pr {CREATE} --fill")[0][2], "1")
        self.assertEqual(invocations(f"gh pr {CREATE} --fill")[0][2:4], ("0", "top"))
        self.assertEqual(invocations(f'echo "`gh issue {COMMENT}`"')[0][3], "sub")
        # 文として cwd・GH_REPO を変えたら、env -C・読めない GH_REPO と同じ印 (#1823)
        self.assertEqual(invocations(f"cd /tmp && gh pr {CREATE} --fill")[0][1:3], ("=", "1"))
        self.assertEqual(invocations(f"export GH_REPO=x/y && gh pr {CREATE} --fill")[0][1:3], ("?", "0"))
        self.assertEqual(invocations(f"unset GH_REPO; GH_REPO=x/y gh pr {CREATE} --fill")[0][1], "+x/y")
        self.assertEqual(invocations(f"(cd /tmp) && gh pr {CREATE} --fill")[0][2], "0")
        self.assertEqual(invocations(f"gh pr view 1 && cd /tmp && gh pr {CREATE} --fill")[0][2], "0")

    def test_quoted_words_keep_their_spaces_out_of_the_flags(self):
        """引用の中の空白は伏せる。本文に書いた -R や --help を旗と取り違えない。"""
        (_, _, _, _, fragment), = invocations(f'gh issue {COMMENT} 1 --body "see -R x/y --help"')
        self.assertNotIn(" -R ", fragment)
        self.assertNotIn(" --help", fragment)


class HeredocTest(unittest.TestCase):
    """ヒアドキュメントの開きは、引用と注釈の外の << だけ (#1729 の 2 回目の反証)。

    行単位の前段が引用も注釈も見ずに <<WORD を探していた頃は、その後ろの行がすべて
    判定から消えた。
    """

    def test_quoted_or_commented_opener_does_not_hide_the_next_lines(self):
        for command in (
            f'git commit -m "fix <<EOF parse"\ngh issue {COMMENT} 1 -b x',
            f"echo '<<EOF'\ngh issue {COMMENT} 1 -b x",
            f"# note <<EOF\ngh issue {COMMENT} 1 -b x",
        ):
            with self.subTest(command=command):
                self.assertEqual(judge(command, f"issue[[:space:]]+{COMMENT}"), 0)

    def test_body_is_skipped_and_the_command_after_it_is_read(self):
        command = f"cat <<'EOF' > x\ngh issue {COMMENT} 1 -b x\nEOF\ngh pr {CREATE} --fill"
        self.assertNotEqual(judge(command, f"issue[[:space:]]+{COMMENT}"), 0)
        self.assertEqual(judge(command, f"pr[[:space:]]+{CREATE}"), 0)

    def test_two_heredocs_on_one_line(self):
        command = f"cat <<A <<'B'\ngh issue {COMMENT} 1\nA\ngh pr {CREATE}\nB\ngh pr view 1"
        self.assertEqual([r[4] for r in invocations(command)], ["gh pr view 1"])

    def test_herestring_is_not_a_heredoc(self):
        self.assertEqual(judge(f"cat <<< x\ngh issue {COMMENT} 1 -b x", f"issue[[:space:]]+{COMMENT}"), 0)


class LengthTest(unittest.TestCase):
    """読む時間は長さに比例する (#1729 の 2 回目の反証)。

    1 文字ずつ文字列を継ぎ足すと長さの 2 乗かかり、480KB の二重引用の本文でガード 1 本が
    16 秒を越えた。フックの timeout は 10 秒で、越えると判定が出ずに素通しになりうる。
    上限は手元で 1 秒前後のものに、遅い機械の分の余裕を持たせてある。

    **測るのは壁時計ではなく、ガード (子とその子) が使った CPU 時間** (#1857)。2 乗の退行は
    ガード自身の CPU として現れるが、壁時計は他の誰かが CPU を使った分まで足す。hooks-test を
    並列にしたら、退行が無いのに 5.87 秒で赤になった。

    **測る区間では、読んだ結果をファイルに受けてから回す** (MEASURED)。フックと同じ
    `done < <(gh_invocations …)` の形だと、`<(...)` の中の subshell は bash が回収したとき
    だけ RUSAGE_CHILDREN に入る。判定は途中の `exit 0` で抜けるので、回収より先に抜けると
    読む仕事が 0 秒と数えられ、2 乗の退行があっても緑になる (#1857 の反証)。前面で最後まで
    待てば、終わる順番によらず全部が数えられる。判定そのものの形はほかの検査が見ている。
    """

    MEASURED = """
out=$(mktemp)
gh_invocations "$1" > "$out"
while IFS=$'\\t' read -r token repo chdir place fragment; do
  gh_fragment_is "$fragment" "$2" && { rm -f "$out"; exit 0; }
done < "$out"
rm -f "$out"
exit 1
"""

    LIMIT = 5.0
    SIZE = 500_000

    @staticmethod
    def children_cpu():
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        return usage.ru_utime + usage.ru_stime

    def time_of(self, command):
        start = self.children_cpu()
        self.assertEqual(judge(command, f"issue[[:space:]]+{COMMENT}", self.MEASURED), 0)
        return self.children_cpu() - start

    def repeat(self, piece):
        """piece を繰り返して SIZE バイトに届かせる。"""
        return piece * (self.SIZE // len(piece.encode()) + 1)

    def test_long_double_quoted_body(self):
        body = self.repeat("本文の行です。\n")
        self.assertLess(self.time_of(f'gh issue {COMMENT} 1 --body "{body}"'), self.LIMIT)

    def test_long_body_with_many_special_characters(self):
        body = self.repeat("本文 $HOME と \\\" と `x` と -R x/y --help\n")
        self.assertLess(self.time_of(f'gh issue {COMMENT} 1 --body "{body}"'), self.LIMIT)

    def test_long_unquoted_command(self):
        words = self.repeat("word ")
        self.assertLess(self.time_of(f"gh issue {COMMENT} 1 -b x {words}"), self.LIMIT)

    def test_long_heredoc_body(self):
        lines = self.repeat("本文の行 <<X ; && ' \"\n")
        self.assertLess(
            self.time_of(f"gh issue {COMMENT} 1 -F - <<'EOF'\n{lines}EOF"), self.LIMIT
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
            # 呼び出しごとの口を、その呼び出しの列で呼んでいるか。関数名の部分一致だけだと、
            # 使っていない口の名前でも通ってしまう (#1729 の 2 回目の反証)
            self.assertRegex(
                text,
                r'invocation_targets_other_repo "\$fragment" "\$repo" "\$chdir" "\$cwd"',
                f"{name} が宛先を見ていない",
            )
            self.assertRegex(text, r'< <\(gh_invocations "\$command"\)', f"{name} が呼び出しを読んでいない")

    def test_the_library_has_no_mouth_without_a_caller(self):
        """コマンド全体を 1 回で問う口は、フックが呼ばなくなったので持たない (#1729)。"""
        text = LIB.read_text(encoding="utf-8")
        for dead in ("is_gh_subcommand()", "targets_other_repo()", "strip_heredoc_bodies()"):
            self.assertNotIn(dead, text.replace("invocation_targets_other_repo()", ""))

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

    **一覧は数え上げない** — `.claude/settings.json` の PreToolUse 配線から引くので、
    4 本目を足して配線した人がここを直さなくても掛かる (`bash_invocation_test.py` が
    検査ファイル全体を glob して `/bin/bash` を見張っているのと同じ構え)。
    """

    def hooks(self):
        """フックの一覧は **配線**から引く。名前の綴りでは決めない (#944)。

        以前は `scripts/*-guard.sh` を glob していたが、それが見ていたのは「フックで
        ある」ことではなく名前だった。CI から呼ぶ `scripts/parent-guard.sh` (Issue
        ツリーの見張り・#798) を置いた日に、フックでないスクリプトが下の 4 つの検査へ
        巻き込まれた — `guard-lib.sh` が持つのは「Claude Code へ返す JSON の綴りと
        fail open」で、CI のスクリプトには意味が無い。

        **glob より広い。** 配線されていれば名前が `-guard.sh` でなくても掛かる。
        逆に配線されていないフックは**そもそも効いていない**ので、その出口の綴りを
        見張る意味が無い (同じ読み方の前例は pr_identity_guard_test.py の WiringTest)。
        """
        settings = json.loads((REPO / ".claude" / "settings.json").read_text())
        found = set()
        for entry in settings["hooks"]["PreToolUse"]:
            for hook in entry["hooks"]:
                named = re.search(r"scripts/([A-Za-z0-9_.-]+\.sh)", hook["command"])
                if named:
                    found.add(REPO / "scripts" / named.group(1))
        # 対象が 0 件の緑は、通っていることに意味が無い (置き場の移動を緑のまま
        # 見逃さないため。bash_invocation_test.py と同じ構え)
        self.assertTrue(found, "検査対象のフックが 1 つも無い")
        return sorted(found)

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
