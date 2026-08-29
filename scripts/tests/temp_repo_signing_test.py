#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""使い捨ての一時リポジトリが、手元の署名設定を継いでいないことの検査 (#344)。

`git init` で作った一時リポジトリは、手元のグローバル設定をそのまま継ぐ。
メンテナの環境は `commit.gpgsign=true` + `gpg.format=ssh` で署名鍵を SSH
エージェントが持つので、**エージェントが応えられない一瞬**があると `git commit`
が 128 で落ちる — 検査の対象とは何の関係もない失敗で、しかも CI では起きない
(ランナーにグローバル設定が無い)。打ち直せば消える赤は、`make ci-check` が
merge の条件である以上「打ち忘れ」と見分けがつかない。

事象そのものは「一時リポジトリを作る 4 本のうち 2 本で、同じ 2 行が抜けていた」
だった。抜けたことに気付ける場所が人の記憶しか無いのが原因なので、**条件を
ファイルに持たせる**。中身ではなく書かれ方を見る静的な検査で、実行はミリ秒で済む
(署名を強制した環境で各モジュールを実際に走らせる案は、通る側が 40 秒かかるので
採らなかった)。

**判定は緩めに倒してある** — git を触っていて `"init"` を含むファイルに要求する
ので、リポジトリを作らないファイルを巻き込むことがある。そのとき増えるのは効き目の
無い 1 行だけで、取りこぼして「ときどき赤い」に戻るほうがずっと高くつく。
"""

import re
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SELF = Path(__file__).name

GIT_INIT = re.compile(r"[\"']init[\"']")
GIT_TAG = re.compile(r"[\"']tag[\"']")

HOW = (
    "使い捨てのリポジトリでは署名を切る "
    '(setUp で self.git("config", "commit.gpgsign", "false")、あるいは '
    'git の呼び口に -c commit.gpgsign=false)。'
)


def normalized(source: str) -> str:
    """引用符・空白・カンマを `=` に潰して、2 通りの書き方を同じ形にする。

        self.git("config", "commit.gpgsign", "false")  ->  =config=commit.gpgsign=false=
        ["git", "-c", "commit.gpgsign=false", *args]   ->  =-c=commit.gpgsign=false=
    """
    return re.sub(r"[\"'\s,]+", "=", source)


def repo_creating_tests():
    """一時リポジトリを作っているとみられる検査を集める。"""
    for path in sorted(TESTS.glob("*_test.py")):
        if path.name == SELF:
            continue
        source = path.read_text(encoding="utf-8")
        if "git" in source and GIT_INIT.search(source):
            yield path, source


class TempRepoSigningTest(unittest.TestCase):
    def test_detector_finds_something(self):
        """検出が空振りしていないこと。

        この検査の他の 2 件は「見つけた対象が条件を満たすか」しか見ないので、
        検出が壊れると誰も落とせないまま緑になる。名前は数えない (改名で
        ずれる) — 1 本でも見つかっていれば検出は生きている。
        """
        found = [path.name for path, _ in repo_creating_tests()]
        self.assertTrue(
            found,
            "一時リポジトリを作る検査が 1 本も見つからない — "
            "この検査の検出側が壊れている疑いがある",
        )

    def test_commit_signing_is_disabled(self):
        for path, source in repo_creating_tests():
            with self.subTest(test=path.name):
                # assertIn ではなく assertTrue — 落ちたときに潰した後のファイル
                # 全体が失敗メッセージに流れ込むのを避ける
                self.assertTrue(
                    "commit.gpgsign=false" in normalized(source),
                    f"{path.name} は一時リポジトリを作るのに commit 署名を切っていない。{HOW}",
                )

    def test_tag_signing_is_disabled_where_tags_are_made(self):
        """タグを打つ検査だけは `tag.gpgsign` も要る (`commit.gpgsign` は効かない)。"""
        for path, source in repo_creating_tests():
            if not GIT_TAG.search(source):
                continue
            with self.subTest(test=path.name):
                self.assertTrue(
                    "tag.gpgsign=false" in normalized(source),
                    f"{path.name} はタグを打つのに tag 署名を切っていない。{HOW}",
                )


if __name__ == "__main__":
    unittest.main()
