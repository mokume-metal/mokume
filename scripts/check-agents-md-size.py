#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""AGENTS.md の分量を、合流先との差と節ごとの上限で持つ (#737 / #1668)。

`CLAUDE.md` は `@AGENTS.md` の 1 行なので、AGENTS.md は毎セッション全文が読み込まれる
固定費である。#505 で 25,815 → 14,016 字に畳んだが、その後の改訂は 26 件すべてが
増える向きで、9 日で元の分量へ戻った。**足す側のコストはゼロで、抜く側には
きっかけが無い** — この非対称を文書ルールで塞がないのは ADR-0001 原則 8 のとおり。

## 1. 全体は合流先との差で持つ

比べる相手は**合流先との分岐点 (PR の base と head の merge-base) の AGENTS.md** で、
判定は `scripts/review-gate.sh` が PR の文脈で行う (サブコマンド `growth`)。

- 差が 0 以下 → 緑。縮めた PR に手作業は要らない
- 差が正 → PR 本文に増分の宣言が要る。宣言が無いか、宣言と実測が違えば赤。
  増やす diff は宣言の 1 行としてレビューに晒される

宣言は、行全体をこの形で書いた 1 行である (HTML コメントの中は読まない):

    AGENTS.md の増分: +129

コロンは半角で、数は符号つきでよい整数、「字」は付けない。形が近いが違う行
(全角コロン・「字」付き・バッククォートで囲んだもの) と、宣言が 2 行あるときは、
正しい形を名乗って赤にする — 黙って「宣言なし」と読むと、書いた人は理由に辿り着けない。

**縮めた分を後の追記で黙って食い潰させない** (ラチェットの核心) は、比べる相手が
縮んだ後の main になることで保たれる。次の PR が 1 文字足せば、それは宣言の要る増分である。

**静的な上限にしない。** #505 以降の平均増分 (+450 字/コミット) では数コミットで上限に
届き、その後は 1 文字の diff で上げられる。「上げる理由を書く」は文書ルールに戻る。

### 記録値のファイルをやめた理由 (#1668)

以前は字数の記録値を 1 行のファイルに置き、実測と等しいときだけ緑にしていた (#737)。
値を動かす diff がその 1 行だけになり、レビューで最も見えるからだった。ところが
AGENTS.md に触れる PR が同じ時期に 2 本あると、どちらもその 1 行を書き換える。
**AGENTS.md の本文は触れた箇所が違えば自動で合流するのに、記録値の 1 行だけが衝突し**、
merge queue から外れた (#1664 × #1665・#1666、#1376 × #1393)。重要パスに触れる PR では
衝突を解く push が承認を落とす (#612)。共有の 1 か所をやめるのは #149 (REUSE.toml) と
同じ直し方である。

**merge-base と比べ、base の先端とは比べない。** 先端と比べると、後から入った他の PR の
増減が自分の増分に混ざる。範囲の重ならない合流では字数の差が PR ごとの増分の和になるので、
merge queue で group の base と比べた差も PR 時点の増分と一致する (テストが一時リポジトリで
固定する)。merge_group で判定する形は採らない — 宣言を squash のメッセージから読むことに
なり、定義ファイルに無いリポジトリ設定に依存し、手元の結果と割れる (#1668 の決定)。

手元の `make agents-md-size` は、`git merge-base HEAD origin/main` との差を**表示だけ**する。
赤にしないのは、宣言が PR 本文にあって手元からは読めないからである。CI
(`GITHUB_ACTIONS=true`) と git の外では表示も省く。

## 2. 節ごとの上限

`## ` 見出しで節を区切り (`###` は親の節に含める)、`SECTION_LIMIT` を越えた節を名指しで
赤にする。全体の差だけでは、ある節を削った分を別の節の経緯で埋め戻せる。これは
`make agents-md-size` (`make ci-check` に含まれる) で効く。

**値の根拠**: 上限は最大の節に短い段落 1 つぶんの余地を残す値に置く。最大の節より小さい
上限はどんな配置でも満たせない。#1208 の後は「止まって見えるときの読み分け」の 3,096 字が
床で 3,200 字だったが、#1510 で場面限定の規律を「場面別の入口」の 1 行ずつへ畳んだ後は
「進め方」の約 1,200 字が最大なので、1,500 字にした。

## 3. 何を書き、何を書かないか

赤を見て足し方を考えるときの基準 (#1510)。AGENTS.md は毎回の作業で要る規律だけを持つ。

- 特定の場面でしか要らない規律は「場面別の入口」の 1 行と読む先だけにし、本体は
  その場面で読まれる場所 (スクリプトの冒頭・入れ子の AGENTS.md・ADR) に置く
- フェーズも進捗も書かない。どこまで出来ているかは `Sources/` と Issue が
  正典で、写すと触る理由が無いまま古くなる
- 機構が差し戻すときに手順まで示すものは、フックが効かない読み手に要る分だけを書く
- `CONTRIBUTING.md` は人間の入口として案内だけを持ち、規約の写しを置かない

入れ子の `docs/decisions/AGENTS.md` はこの検査の外にある。そちらは ADR を読んだときにしか
読み込まれない (毎セッションの固定費ではない) ので、膨らんだ実害が出るまで広げない (ADR-0008)。

## 数え方

**単位は文字数 (Unicode スカラー) で、UTF-8 として読んだ `len()` で数える。** `wc -m` は
使わない — `LC_CTYPE=C` のシェルではバイト数を返し、#737 の起票はその罠を踏んで
14,016 字と 39,217 バイトを比べた。ロケールに依る数え方は割れても黙って通る。
バイト数・行数も使わない (日本語は 1 行が長く、行数と読む負荷が比例しない)。
**数え方はこのスクリプト 1 か所に保つ** — review-gate は本文を取ってきてここへ渡すだけで、
自分では数えない。

コードフェンスの中の `## ` は見出しに数えない。潰し方は `check-docs-links.py` の
`mask_fences` を借りる (写すと片方だけが直る — `check-external-assets.py` と同じ理由)。

## 既存の検査で済まない理由 (ADR-0008 決定 5)

節の上限: `docs-links` は指し先の不在、`adrs` は ADR の番号と状態欄、`changelog-lint` は
断片の書き方を見ていて、どれも分量を見ていない。どれかの責務を広げると「リンクの検査が
文書の長さで赤くなる」ことになり、赤の意味が割れる (`check-adrs.sh` が docs-links を
広げなかったのと同じ判断)。

全体の差 (#1668): 記録値のファイルを畳み、PR 本文の宣言を読む責務を既に本文の節を読んで
いる `review-gate.sh` へ広げた (段 3「置き換える」— 部品は増えない)。

実行は make agents-md-size (make ci-check に含まれる)。review-gate からは
`check-agents-md-size.py growth <分岐点の AGENTS.md> <head の AGENTS.md>` と呼び、
PR 本文 (HTML コメントを除いたもの) を標準入力へ渡す。
"""

import argparse
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
AGENTS = REPO / "AGENTS.md"

# 節ごとの上限 (字)。根拠は冒頭の「2. 節ごとの上限」
SECTION_LIMIT = 1500

# 越えたときに名乗る降ろし先 (AGENTS.md 冒頭の宣言と同じ 3 つ)
OFFLOAD = "決定の根拠は ADR、経緯と実測は Issue / PR、機構の内部と手順はスクリプトの冒頭コメントと --help"

# 増分の宣言 (冒頭の「1.」)。行全体で一致させる。`\d` は全角数字にも一致するので使わない
DECLARATION = re.compile(r"AGENTS\.md の増分: ([+-]?[0-9]+)")
# 宣言のつもりで形が違う行。行頭の空白・箇条書きの記号・引用・バッククォートの後に
# 「AGENTS.md の増分」とコロン (全角を含む) が来る行を拾う。文中で触れただけの行は拾わない
NEAR_DECLARATION = re.compile(r"[\s`>*+\-]*AGENTS\.md\s*の増分\s*[:：]")
DECLARATION_FORM = "AGENTS.md の増分: +N"
DECLARATION_HINT = (
    f"行全体を「{DECLARATION_FORM}」の形で 1 行だけ書く "
    "(コロンは半角、N は整数で「字」を付けない、バッククォートや箇条書きで囲まない)"
)


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


def check(text: str, limit: int = SECTION_LIMIT) -> list[str]:
    """節の上限を越えた理由を並べて返す。空なら緑。"""
    problems = []
    for title, size in sections(text):
        if size > limit:
            problems.append(
                f"節「{title}」が上限 {limit} 字を {size - limit} 字超えている ({size} 字)。"
                f"{OFFLOAD} へ降ろす"
            )
    return problems


def parse_declaration(body: str) -> tuple[int | None, list[str]]:
    """PR 本文から増分の宣言を読む。(宣言の値 または None, 形の問題) を返す。

    本文は HTML コメントを除いたものを受け取る (除くのは review-gate の
    strip_html_comments)。改行は CRLF でもよい。
    """
    values = []
    problems = []
    for line in body.splitlines():
        m = DECLARATION.fullmatch(line)
        if m:
            values.append(int(m.group(1)))
        elif NEAR_DECLARATION.match(line):
            problems.append(f"増分の宣言の形が違う: {line.strip()!r}。{DECLARATION_HINT}")
    if len(values) > 1:
        problems.append(f"増分の宣言が {len(values)} 行ある。{DECLARATION_HINT}")
    return (values[0] if len(values) == 1 else None), problems


def growth_problems(base: str, head: str, declared: int | None) -> list[str]:
    """分岐点 (base) と head の AGENTS.md を比べ、宣言と突き合わせた赤の理由を返す。"""
    actual = len(head) - len(base)
    measured = f"分岐点 {len(base)} 字 → この PR {len(head)} 字"
    if declared is None:
        if actual <= 0:
            return []
        return [
            f"AGENTS.md が合流先との分岐点より {actual} 字増えているのに、PR 本文に増分の宣言が無い ({measured})。"
            f"この文書は規律だけを書く — {OFFLOAD} へ降ろして同じ量を減らす。"
            f"それでも増やすなら、PR 本文に次の 1 行を書いてレビューに晒す: AGENTS.md の増分: +{actual}"
        ]
    if declared != actual:
        fix = (
            f"宣言を「AGENTS.md の増分: {actual:+d}」に直す"
            if actual > 0
            else "増えていないので宣言の行を消す"
        )
        return [
            f"PR 本文の増分の宣言 ({declared:+d}) が実測 ({actual:+d}) と違う ({measured})。"
            f"{fix}。増やす前に {OFFLOAD} へ降ろせないかを見る"
        ]
    return []


def local_growth(agents: Path) -> str | None:
    """手元の `git merge-base HEAD origin/main` との差を表示用の 1 行で返す。

    赤にはしない (宣言は PR 本文にあって手元からは読めない)。CI と git の外、
    分岐点が引けないときは None を返して何も言わない。
    """
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return None

    def git(*args):
        return subprocess.run(
            ["git", "-C", str(agents.parent), *args], capture_output=True, check=False
        )

    prefix = git("rev-parse", "--show-prefix")
    if prefix.returncode != 0:
        return None
    base_commit = git("merge-base", "HEAD", "origin/main")
    if base_commit.returncode != 0:
        return None
    sha = base_commit.stdout.decode().strip()
    rel = prefix.stdout.decode().strip() + agents.name
    shown = git("show", f"{sha}:{rel}")
    if shown.returncode != 0:
        return None
    base = shown.stdout.decode("utf-8")
    head = agents.read_text(encoding="utf-8")
    actual = len(head) - len(base)
    line = f"参考: origin/main との分岐点 ({sha[:7]}) より {actual:+d} 字"
    if actual > 0:
        line += f"。PR 本文に宣言の 1 行が要る (review-gate が突き合わせる): AGENTS.md の増分: +{actual}"
    return line


def run_growth(base_path: Path, head_path: Path) -> int:
    base = base_path.read_text(encoding="utf-8")
    head = head_path.read_text(encoding="utf-8")
    # ロケールに依らず UTF-8 として読む (冒頭の「数え方」)
    body = sys.stdin.buffer.read().decode("utf-8")
    declared, problems = parse_declaration(body)
    if not problems:
        problems = growth_problems(base, head, declared)
    if problems:
        for p in problems:
            print(f"NG: {p}", file=sys.stderr)
        return 1
    actual = len(head) - len(base)
    note = "宣言どおり" if declared is not None else "宣言は要らない"
    print(f"ok: AGENTS.md の増分は {actual:+d} 字で{note} (分岐点 {len(base)} 字 → この PR {len(head)} 字)")
    return 0


def main(argv: list[str]) -> int:
    # 出力も UTF-8 に固定する。C ロケールで Python の読み替え (PEP 538 / 540) が効かない
    # 環境では、日本語の 1 行目を出したところで UnicodeEncodeError になる
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="AGENTS.md の分量を合流先との差と節ごとの上限で検査する")
    parser.add_argument("--agents", type=Path, default=AGENTS)
    sub = parser.add_subparsers(dest="command")
    growth = sub.add_parser(
        "growth", help="分岐点と head の AGENTS.md を比べ、標準入力の PR 本文の宣言と突き合わせる"
    )
    growth.add_argument("base", type=Path, help="分岐点 (merge-base) の AGENTS.md")
    growth.add_argument("head", type=Path, help="PR の head の AGENTS.md")
    args = parser.parse_args(argv)

    if args.command == "growth":
        return run_growth(args.base, args.head)

    # ロケールに依らず UTF-8 として読む (冒頭の「数え方」)
    text = args.agents.read_text(encoding="utf-8")
    problems = check(text)
    note = local_growth(args.agents)
    if problems:
        for p in problems:
            print(f"NG: {p}", file=sys.stderr)
        print("節ごとの字数:", file=sys.stderr)
        for title, size in sections(text):
            print(f"  {size:>6}  {title}", file=sys.stderr)
        if note:
            print(note, file=sys.stderr)
        return 1
    print(f"ok: AGENTS.md は {len(text)} 字で、どの節も {SECTION_LIMIT} 字以内")
    if note:
        print(note)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
