#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""AGENTS.md の分量をラチェットと節ごとの上限で持つ (#737)。

`CLAUDE.md` は `@AGENTS.md` の 1 行なので、AGENTS.md は毎セッション全文が読み込まれる
固定費である。#505 で 25,815 → 14,016 字に畳んだが、その後の改訂は 26 件すべてが
増える向きで、9 日で元の分量へ戻った。**足す側のコストはゼロで、抜く側には
きっかけが無い** — この非対称を文書ルールで塞がないのは ADR-0001 原則 8 のとおり。

## 1. 全体はラチェット

記録値 (`scripts/agents-md-highwater.txt`) と実測を比べ、**等しいときだけ緑**にする。

- 実測 > 記録値 → 赤。足した分を降ろすか、記録値を上げる diff をレビューに晒す
- 実測 < 記録値 → **これも赤**。記録値を実測まで下げさせる。縮めた分を後の追記で
  黙って食い潰させないためで、これがラチェットの核心である

**静的な上限にしない。** #505 以降の平均増分 (+450 字/コミット) では数コミットで上限に
届き、その後は 1 文字の diff で上げられる。「上げる理由を書く」は文書ルールに戻る。
記録値が下がる向きにしか自然に動かなければ、1 文字足すには同じ量を降ろすことになる。

記録値を専用のファイルに値 1 行で置くのは、値を動かす diff がその 1 行だけになり、
レビューで最も見えるからである (スクリプト内の定数や Makefile の変数だと埋もれる)。

## 2. 節ごとの上限

`## ` 見出しで節を区切り (`###` は親の節に含める)、`SECTION_LIMIT` を越えた節を名指しで
赤にする。全体のラチェットだけでは、ある節を削った分を別の節の経緯で埋め戻せる。

**値の根拠** (#1208 で降ろした後の実測): 最大の節は「止まって見えるときの読み分け」の
3,096 字で、そのうち症状 → 対処の表 8 行が約 2,000 字を占め、規律なので縮まない。
**この床より小さい上限はどんな配置でも満たせない。** 上限はその節に短い段落 1 つぶんの
余地を残す値に置いた。他の節は最大でも 2,893 字である。

## 数え方

**単位は文字数 (Unicode スカラー) で、UTF-8 として読んだ `len()` で数える。** `wc -m` は
使わない — `LC_CTYPE=C` のシェルではバイト数を返し、#737 の起票はその罠を踏んで
14,016 字と 39,217 バイトを比べた。ロケールに依る数え方は割れても黙って通る。
バイト数・行数も使わない (日本語は 1 行が長く、行数と読む負荷が比例しない)。

コードフェンスの中の `## ` は見出しに数えない。潰し方は `check-docs-links.py` の
`mask_fences` を借りる (写すと片方だけが直る — `check-external-assets.py` と同じ理由)。

## 既存の検査で済まない理由 (ADR-0008 決定 5)

`docs-links` は指し先の不在、`adrs` は ADR の番号と状態欄、`changelog-lint` は断片の
書き方を見ていて、どれも分量を見ていない。どれかの責務を広げると「リンクの検査が
文書の長さで赤くなる」ことになり、赤の意味が割れる (`check-adrs.sh` が docs-links を
広げなかったのと同じ判断)。

実行は make agents-md-size (make ci-check に含まれる)。
"""

import argparse
import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
AGENTS = REPO / "AGENTS.md"
HIGHWATER = REPO / "scripts" / "agents-md-highwater.txt"

# 節ごとの上限 (字)。根拠は冒頭の「2. 節ごとの上限」
SECTION_LIMIT = 3200

# 越えたときに名乗る降ろし先 (AGENTS.md 冒頭の宣言と同じ 3 つ)
OFFLOAD = "決定の根拠は ADR、経緯と実測は Issue / PR、機構の内部と手順はスクリプトの冒頭コメントと --help"


def _mask_fences():
    """フェンスを潰す関数を `check-docs-links.py` から借りる (冒頭の「数え方」)。"""
    path = Path(__file__).resolve().parent / "check-docs-links.py"
    spec = importlib.util.spec_from_file_location("check_docs_links", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.mask_fences


mask_fences = _mask_fences()


def sections(text: str) -> list[tuple[str, int]]:
    """`## ` 見出しで区切った節と、その字数を順に返す。

    見出しの前の部分は `(冒頭)` と名乗る。節の字数は見出しの行から次の見出しの
    直前までを改行込みで数える (節の間の改行 1 つは数えない)。
    """
    lines = text.split("\n")
    masked = mask_fences(text).split("\n")
    result = []
    title = "(冒頭)"
    start = 0
    for i, line in enumerate(masked):
        if line.startswith("## "):
            result.append((title, len("\n".join(lines[start:i]))))
            title = line[3:].strip()
            start = i
    result.append((title, len("\n".join(lines[start:]))))
    return result


def check(text: str, highwater: int, limit: int = SECTION_LIMIT) -> list[str]:
    """赤の理由を並べて返す。空なら緑。"""
    problems = []
    actual = len(text)
    if actual > highwater:
        problems.append(
            f"AGENTS.md が記録値を {actual - highwater} 字超えている (実測 {actual} / 記録値 {highwater})。"
            f"この文書は規律だけを書く — {OFFLOAD} へ降ろして同じ量を減らす。"
            f"それでも上げるなら scripts/agents-md-highwater.txt を {actual} へ書き換え、その diff をレビューに晒す"
        )
    elif actual < highwater:
        problems.append(
            f"AGENTS.md が記録値より {highwater - actual} 字短い (実測 {actual} / 記録値 {highwater})。"
            f"記録値を {actual} へ下げてください (scripts/agents-md-highwater.txt)。"
            "縮めた分は戻せない — 記録値を据え置くと、後の追記が縮めた分を黙って食い潰す"
        )
    for title, size in sections(text):
        if size > limit:
            problems.append(
                f"節「{title}」が上限 {limit} 字を {size - limit} 字超えている ({size} 字)。"
                f"{OFFLOAD} へ降ろす"
            )
    return problems


def read_highwater(path: Path) -> int:
    """記録値を読む。`#` で始まる行 (SPDX ヘッダと説明) と空行は読み飛ばす。"""
    values = [
        line.strip()
        for line in path.read_text(encoding="utf-8").split("\n")
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if len(values) != 1 or not values[0].isdigit():
        raise ValueError(f"{path} はコメント以外に字数 1 つだけを持つ (読めた中身: {values!r})")
    return int(values[0])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="AGENTS.md の分量をラチェットと節ごとの上限で検査する")
    parser.add_argument("--agents", type=Path, default=AGENTS)
    parser.add_argument("--highwater", type=Path, default=HIGHWATER)
    args = parser.parse_args(argv)

    # ロケールに依らず UTF-8 として読む (冒頭の「数え方」)
    text = args.agents.read_text(encoding="utf-8")
    try:
        highwater = read_highwater(args.highwater)
    except ValueError as e:
        print(f"NG: {e}", file=sys.stderr)
        return 1

    problems = check(text, highwater)
    if problems:
        for p in problems:
            print(f"NG: {p}", file=sys.stderr)
        print("節ごとの字数:", file=sys.stderr)
        for title, size in sections(text):
            print(f"  {size:>6}  {title}", file=sys.stderr)
        return 1
    print(f"ok: AGENTS.md は記録値どおり {len(text)} 字で、どの節も {SECTION_LIMIT} 字以内")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
