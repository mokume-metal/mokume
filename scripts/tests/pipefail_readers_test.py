#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`pipefail` の下で、早く抜ける読み手 (`grep -q`・`head`) へ流すパイプを赤にする (#1900)。

**`set -o pipefail` の下では、`… | grep -q` と `… | head` は書き手を殺しうる。** 読み手が
最初の行で抜けると、まだ書いている側は読み手のいないパイプへ書いて SIGPIPE (141) で止まる。
`pipefail` はパイプ全体をその失敗で返すので、`if ! … | grep -q` の条件が裏返る。`set -e` の
下の `x=$(… | head -1)` なら、スクリプトごと止まる。書き手の出力が短ければ書き終わってから
読み手が抜けるので表に出ず、出力が長いときだけ踏む。#1900 では `review-gate` が、18KB の
「反証」節を「空」と判定して #1897 を差し戻した。

直し方は 2 通りある。
- `grep -q` は、here-string (`grep -q … <<<"$x"`) か `[ -n "$(…)" ]` で読む。here-string の
  書き手は bash 自身なので止まらない
- `head -N` は `sed -n '1,Np'` にする。sed は入力を最後まで読むので、書き手を止めない

書き手の出力が必ず短い (1 行しか出ないなど) と言える所は、行末に `# pipefail-ok: <理由>` を
置けば許す。

対象は、`pipefail` を含む `scripts/` の下のシェルスクリプト (追跡 + 未追跡 − 無視) である。
注釈の行は見ない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

EARLY_READER = re.compile(r"(?<!\|)\|(?![|&])\s*(?:grep\b[^|#]*?\s(?:-[A-Za-z]*q[A-Za-z]*|--quiet|-m\s*\d+)\b|head\b)")
ALLOW = re.compile(r"#\s*pipefail-ok:\s*\S")


def logical_lines(text):
    """物理行を、行末の `|` で続くパイプごとに繋いだ論理行にする。(先頭の行番号, 論理行) を返す。

    `gh … |` の次の行に `grep -q …` を置く形も同じパイプなので、繋いでから見る (#1900 の反証)。
    """
    joined, start, parts = [], None, []
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        if start is None:
            start = number
        parts.append(line.strip())
        stripped = line.rstrip()
        if stripped.endswith("|") and not stripped.endswith("||"):
            continue
        joined.append((start, " ".join(parts)))
        start, parts = None, []
    if parts:
        joined.append((start, " ".join(parts)))
    return joined


def early_readers(text):
    """テキストの中の、早く抜ける読み手へ流す論理行を (行番号, 行) で返す。"""
    return [
        (number, line)
        for number, line in logical_lines(text)
        if EARLY_READER.search(line) and not ALLOW.search(line)
    ]


SOURCED = re.compile(r'^\s*(?:\.|source)\s+(?:"\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/|scripts/)([\w.-]+\.sh)', re.M)


def pipefail_scripts(root=REPO):
    """pipefail を持つ scripts の下のシェルスクリプトと、それが読み込むライブラリ (#1900 の反証)。

    ライブラリ (guard-lib.sh など) は自分では pipefail を立てないが、読み込んだ側の pipefail の
    下で走る。

    **見る範囲は「git add -A したときに CI の木になるもの」(追跡 + 未追跡 − 無視)** (#2015)。
    追跡済みだけだと、新しい scripts/x.sh の違反が git add 前の手元では見つからず、push した
    後の CI で初めて赤になる。挙がったパスは実在するとは限らない (`git rm` していない削除は
    index に旧パスが残り、エディタの退避リンクは先が無いまま未追跡で残る) ので、読む前に
    落とす。名前は -z で割る (非 ASCII の名前は C 引用符つきで返る)。
    """
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
         "scripts/*.sh", "scripts/**/*.sh"],
        cwd=root, capture_output=True, text=True, check=True,
    ).stdout.split("\0")
    texts = {
        relative: (root / relative).read_text(encoding="utf-8")
        for relative in listed
        if relative and (root / relative).is_file()
    }
    targets = {relative for relative, text in texts.items() if "pipefail" in text}
    pending = list(targets)
    while pending:
        for name in SOURCED.findall(texts[pending.pop()]):
            relative = f"scripts/{name}"
            if relative in texts and relative not in targets:
                targets.add(relative)
                pending.append(relative)
    for relative in sorted(targets):
        yield relative, texts[relative]


class EarlyReaderPatternTest(unittest.TestCase):
    """見分けの規則そのもの。"""

    def test_hits_the_forms_that_can_kill_the_writer(self):
        for line in (
            'if ! jq -r .body <<<"$j" | grep -Eq "^# x"; then',
            "  printf '%s\\n' \"$1\" | grep -Fxq \"$2\"",
            'find . -name x | grep -q .',
            'x=$(find Sources -name K.metal | head -1)',
            'echo "$err" | head -3 >&2',
            'a | grep --quiet b',
            'a | grep -m1 b',
            'gh x -q .body 2>/dev/null |\n    grep -qF "$MARK"',
            'printf x |\n  grep -oE y |\n  head -1 |\n  tr a b',
        ):
            with self.subTest(line=line):
                self.assertEqual(len(early_readers(line)), 1)

    def test_leaves_the_safe_forms_alone(self):
        for line in (
            'grep -q x <<<"$y"',
            '[ -n "$(find . -name x)" ]',
            "x=$(find . -name K.metal | sed -n '1p')",
            'a | grep -c b',
            'a | grep -v q',
            '# a | grep -q b は注釈なので見ない',
            'a | head_count',
            'git rev-parse -q --verify x >/dev/null 2>&1 || head="origin/$head"',
            'a || grep -q b',
            'a |\n  sed -n 1p',
        ):
            with self.subTest(line=line):
                self.assertEqual(early_readers(line), [])

    def test_a_stated_reason_allows_the_line(self):
        self.assertEqual(early_readers('v=$(tool --version | head -1)  # pipefail-ok: 1 行しか出ない'), [])
        self.assertEqual(len(early_readers('v=$(tool --version | head -1)  # pipefail-ok:')), 1)


class PipefailScriptsListingTest(unittest.TestCase):
    """見るスクリプトの範囲 (#2015)。基準は「git add -A したときに CI の木になるもの」。

    追跡済みだけだと、新しい scripts/x.sh に書いた早く抜ける読み手が、git add 前の手元では
    見つからず、push した後の CI で初めて赤になる。
    """

    OFFENDER = "set -euo pipefail\nif find . -name x | grep -q .; then echo y; fi\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        subprocess.run(["git", "init", "-q", "."], cwd=self.root, check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit を
        # 打たないので効き目は無いが、抜けを人の記憶で守らないための規約に従う
        subprocess.run(
            ["git", "config", "commit.gpgsign", "false"], cwd=self.root, check=True
        )

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def names(self):
        return [relative for relative, _ in pipefail_scripts(self.root)]

    def test_untracked_script_is_seen_before_git_add(self):
        self.write("scripts/new.sh", self.OFFENDER)
        found = [
            f"{relative}:{number}"
            for relative, text in pipefail_scripts(self.root)
            for number, _ in early_readers(text)
        ]
        self.assertEqual(found, ["scripts/new.sh:2"])

    def test_ignored_script_is_not_seen(self):
        self.write(".gitignore", "scripts/scratch.sh\n")
        self.write("scripts/scratch.sh", self.OFFENDER)
        self.write("scripts/real.sh", "set -euo pipefail\n")
        self.assertEqual(self.names(), ["scripts/real.sh"])

    def test_removed_tracked_script_is_skipped(self):
        # `git rm` していない削除は index に旧パスが残る。読もうとして落ちない
        self.write("scripts/gone.sh", "set -euo pipefail\n")
        self.write("scripts/real.sh", "set -euo pipefail\n")
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        (self.root / "scripts/gone.sh").unlink()
        self.assertEqual(self.names(), ["scripts/real.sh"])

    def test_broken_symlink_is_skipped(self):
        # エディタの退避リンク (`.#x.sh`) は先が無いまま未追跡で残る
        self.write("scripts/real.sh", "set -euo pipefail\n")
        (self.root / "scripts/.#real.sh").symlink_to("nowhere.sh")
        self.assertEqual(self.names(), ["scripts/real.sh"])

    def test_names_with_space_and_non_ascii_are_seen(self):
        # core.quotePath の既定では、非 ASCII の名前は C 引用符つきで返る
        subprocess.run(
            ["git", "config", "core.quotePath", "true"], cwd=self.root, check=True
        )
        self.write("scripts/with space.sh", "set -euo pipefail\n")
        self.write("scripts/日本語.sh", "set -euo pipefail\n")
        self.assertEqual(
            sorted(self.names()), sorted(["scripts/with space.sh", "scripts/日本語.sh"])
        )


class PipefailScriptsTest(unittest.TestCase):
    """実物の scripts/*.sh に、早く抜ける読み手が残っていないこと。"""

    def test_no_early_readers_under_pipefail(self):
        found = []
        for relative, text in pipefail_scripts():
            found += [f"{relative}:{number}: {line}" for number, line in early_readers(text)]
        self.assertEqual(
            found, [],
            "pipefail の下で、早く抜ける読み手へ流している (#1900)。grep -q は here-string か "
            "[ -n \"$(…)\" ] で、head -N は sed -n '1,Np' で読む。書き手が必ず短いなら行末に "
            "# pipefail-ok: <理由> を置く:\n  " + "\n  ".join(found),
        )

    def test_the_writer_really_dies_under_pipefail(self):
        """前提の確かめ: 長い出力を grep -q に流すと、pipefail の下で失敗になる。"""
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "demo.sh"
            script.write_text(
                "set -o pipefail\n"
                "if seq 1 200000 | grep -q 1; then echo NONEMPTY; else echo EMPTY; fi\n"
                "x=$(seq 1 200000)\n"
                "if grep -q 1 <<<\"$x\"; then echo NONEMPTY; else echo EMPTY; fi\n"
            )
            out = subprocess.run(["/bin/bash", str(script)], capture_output=True, text=True, timeout=60).stdout.split()
        self.assertEqual(out, ["EMPTY", "NONEMPTY"])


if __name__ == "__main__":
    unittest.main()
