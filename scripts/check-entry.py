#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""入口のページが、面として成立している形で出ているかを見る (#482)。

**塞ぐのは 2 つである。**

1. **入口が参照の面へ繋がっていない。** 面を 2 つ並べる形 (ADR-0027 決定 3) は、
   行き来がリンクだけで保たれている。そのリンクが切れても両方の面は 200 を返し続ける
   ので、外から見て壊れて見えない。`scripts/check-docs-links.py` は **Markdown しか
   見ない**ため、HTML に書いたリンクは誰も検査していなかった
2. **入口と README で同じことが二重に書かれ、片方だけが古くなる。** 入口の本文の正本は
   `Documentation/index.html` だが、入れ方の 1 行だけは README と重なる。重なった 1 行が
   唯一の漏れ口なので、そこだけを機械で突き合わせる (ADR-0001 原則 9)

**同じ判定を、手元の出力ディレクトリにも公開された URL にも当てる。** 引数が
`http://` / `https://` で始まれば引き、そうでなければ読む — `check-published-reference.py`
と同じ形にしてあるので、手元で通ったものが公開先で落ちたなら、落ちたのは組み立てでは
なく配信である、と引数 1 つで切り分けられる。

## なぜ新しい道具になるのか

[ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 5 の順序で、
段 1 (既存の責務を広げる) を先に当てた。当たらなかった:

- `check-published-reference.py` は DocC の `metadata.json` / `index/index.json` の構造に
  強く依存した**参照の面専用**で、素の HTML はその判定に乗らない
- `check-publication.py` は docstring で「**中身の照合はこの道具の仕事ではない**」と
  自分で線を引いている (あちらは公開の鮮度と配信を見る)

段 2 の native も無い (HTML の構文検査は「リンク先が生きているか」を見ない)。

## 見ないもの

**絵が引けるかは見ない。** 外に置いた資産の死活は `check-external-assets.py` が定期で
見ており、そちらへ HTML を足してある。ここで重ねると、per-PR の検査が相手側の一時的な
不調で揺れる ([#90](https://github.com/mokume-metal/mokume/issues/90) が下した判断)。
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import urllib.error
import urllib.request

ENTRY_NAME = "index.html"
# 参照の面へのリンク。**相対で書く**ので、基準パスに依らずこの形になる
REFERENCE_LINK = re.compile(r"""<a\s[^>]*href=["'](\.?/?reference/)["']""", re.IGNORECASE)
# 絵。src が外部 URL のものだけを資産と数える
IMAGE_SOURCE = re.compile(
    # **`src` の直前で属性の切れ目を要求する。** 要求しないと `data-src=` の末尾に
    # 一致してしまい、絵として飾ってあるだけのものを本物と数える
    r"""<img\s[^>]*?(?<![-\w])src=["'](https?://[^"']+)["']""",
    re.IGNORECASE,
)
# 外部ホストから持ってくる実行物と装飾。**絵とは別に扱う** — 絵が消えてもページは
# 読めるが、これらが消えるとページの意味が変わる
EXTERNAL_SCRIPT = re.compile(r"""<script\s[^>]*src=["']https?://""", re.IGNORECASE)
EXTERNAL_STYLE = re.compile(
    r"""<link\s[^>]*rel=["']stylesheet["'][^>]*href=["']https?://""", re.IGNORECASE
)
# README とページの両方から拾う、入れ方の 1 行。**`<` とバッククォートで止める** —
# HTML では直後に閉じ札が続き、Markdown ではインラインコードの縁が続くので、
# 空白だけを区切りにすると両者で違う文字列が取れて必ず食い違う
BREW_LINE = re.compile(r"brew install [^\s<`]+")

FETCH_TIMEOUT_SECONDS = 30


class Source:
    """出力の読み口。ディレクトリでも URL でも同じ形で引けるようにする。"""

    def __init__(self, target: str) -> None:
        self.target = target.rstrip("/")
        self.is_url = self.target.startswith(("http://", "https://"))
        if not self.is_url:
            self.root = pathlib.Path(self.target)

    def read(self, relative: str) -> bytes | None:
        """無ければ None。**例外は握り潰さない** — 読めなかった理由は呼び出し側が言う。"""
        if self.is_url:
            request = urllib.request.Request(f"{self.target}/{relative}")
            try:
                with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                raise
        path = self.root / relative
        return path.read_bytes() if path.is_file() else None


def brew_line(text: str) -> str | None:
    """入れ方の 1 行。**最初の 1 本だけを見る** — README は他の入れ方も持つが、
    入口が出しているのは Homebrew の 1 行だけである。"""
    match = BREW_LINE.search(text)
    return match.group(0) if match else None


def check(source: Source, readme: pathlib.Path) -> list[str]:
    problems: list[str] = []

    raw = source.read(ENTRY_NAME)
    if raw is None:
        return [f"入口が無い ({source.target}/{ENTRY_NAME})"]
    page = raw.decode("utf-8")

    if not REFERENCE_LINK.search(page):
        problems.append("参照の面 (reference/) へのリンクが無い — 面の行き来が切れている")

    images = IMAGE_SOURCE.findall(page)
    if not images:
        # 0 件を緑にしない。書式が変わって 1 本も拾えなくなった状態は、
        # 絵が消えた状態と同じ見え方をする
        problems.append("外部に置いた絵が 1 枚も無い (書式が変わって拾えていない可能性)")

    if EXTERNAL_SCRIPT.search(page):
        problems.append("外部ホストの <script> がある — 入口は自分だけで成立させる")
    if EXTERNAL_STYLE.search(page):
        problems.append("外部ホストの stylesheet がある — 入口は自分だけで成立させる")

    shown = brew_line(page)
    if shown is None:
        problems.append("入れ方の 1 行 (brew install …) が入口に無い")
    elif readme.is_file():
        expected = brew_line(readme.read_text(encoding="utf-8"))
        if expected is None:
            problems.append(f"README に入れ方の 1 行が無い ({readme})")
        elif shown != expected:
            problems.append(
                f"入れ方の 1 行が README と食い違う: 入口「{shown}」/ README「{expected}」"
            )
    else:
        problems.append(f"README が無い ({readme})")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="組み上がった入口のディレクトリ、または公開された URL")
    parser.add_argument(
        "--readme",
        type=pathlib.Path,
        default=pathlib.Path("README.md"),
        help="入れ方の 1 行を突き合わせる相手 (既定: README.md)",
    )
    arguments = parser.parse_args()

    problems = check(Source(arguments.target), arguments.readme)
    if problems:
        print("入口が面として成立していない:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print("ok: 入口は参照の面へ繋がっていて、入れ方の 1 行が README と一致している")
    return 0


if __name__ == "__main__":
    sys.exit(main())
