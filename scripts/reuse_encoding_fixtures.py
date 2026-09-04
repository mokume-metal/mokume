#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""2048 バイト境界が文字を割るファイルを組む (#817 で shell から出した)。

`scripts/check-reuse-encoding.sh` が使う雛形の生成。#48 の症状を実地で踏ませるための
データで、**検査の中身そのもの**である。

reuse 6.x は SPDX を探す前に先頭 2048 バイトだけを encoding 判定器へ渡す。判定器の一つ
charset_normalizer は途中で切れた UTF-8 に None を返し、そのファイルは「バイナリ」と
見なされて帰属情報なしとして扱われる — 日本語で厚く書くほど踏みやすい。

ASCII のパディングを 0/1/2 バイト入れて落ち位置を 1 バイトずつずらすと、3 文字なら
1 つは文字の切れ目に乗り、残り 2 つは文字を割る。**ヘッダの長さが変わっても、割れる
ケースを必ず含められる。**

**雛形自身を検査する。** 詰め物を書き換えた結果どの雛形も境界で文字を割らなくなると、
呼び出し側の検査は何も検査しないまま緑になる。そうなったら非 0 で落ちる。

使い方:
  python3 scripts/reuse_encoding_fixtures.py <置き場>
"""

from __future__ import annotations

import pathlib
import sys

# REUSE-IgnoreStart — 下の雛形に書く SPDX タグは、このファイル自身の帰属宣言ではなく
# 検査用のデータ
HEADER = (
    "# SPDX-FileCopyrightText: 2026 mokume-metal\n"
    "# SPDX-License-Identifier: MIT\n"
    "# "
).encode("utf-8")
# REUSE-IgnoreEnd
# 日本語のコメントブロックを模した詰め物 (1 文字 3 バイト)
FILLER = "この行は日本語のコメントヘッダを模した検査用の詰め物である。".encode("utf-8")
# reuse が encoding 判定器へ渡す長さ (extract.HEURISTICS_CHUNK_SIZE)
CHUNK = 2048
# 落ち位置をずらすパディングの幅
PADDINGS = (0, 1, 2)


def write_fixtures(work: pathlib.Path, filler: bytes = FILLER) -> list[int]:
    """雛形を置き、2048 バイト境界で文字を割ったパディングの一覧を返す。"""
    split = []
    for pad in PADDINGS:
        prefix = HEADER + b"x" * pad
        body = filler * (((CHUNK * 2) // len(filler)) + 1)
        data = prefix + body + b"\n"
        (work / f"header-{pad}.txt").write_bytes(data)
        try:
            data[:CHUNK].decode("utf-8")
        except UnicodeDecodeError:
            split.append(pad)
    return split


def main(argv: list[str]) -> int:
    work = pathlib.Path(argv[1])
    split = write_fixtures(work)
    if len(split) < 2:
        print(
            f"検査用ファイルが 2048 バイト境界で文字を割っていない (割れたのは {split})。"
            " 詰め物 (FILLER) をマルチバイト文字だけで構成すること",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
