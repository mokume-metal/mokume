#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""参照の面と入口の Topics を、両向きに突き合わせる (#478 / #515)。

**この道具が塞ぐのは「置いても出ない」である。** 面を組み立てる道具は、入力に
入らなかった素材について何も言わないことがある — 変換は成功し、警告も出ず、
出力にだけ存在しない。ビルドの緑は「出ている」を意味しないので、**組み上がった
ものを引いて中身を確かめる**経路を別に持つ (ADR-0027 決定 1)。

**逆向きも見る** (#515)。入口に並べ忘れた公開型があっても、これまで何も起きなかった —
道具が既定の束 (`Structures` / `Enumerations` …) へ自動で入れるので、面には出るし検査も
緑のままになる。読者から見ると、その型だけが意味の無い束の底に落ちる。入口が**人が手で
書く意味の索引**になった (ADR-0027 決定 5) 以上、並べ忘れは起きる前提で拾う。

意図して並べないものは、**面から外す** (`Makefile` の `REFERENCE_OMIT`)。並べない宣言を
別に作らないのは、面に出ているのに索引から外す形を許すと「意味の無い束の底に落ちる」
状態を宣言で正当化できてしまうためである。

**同じ判定を、手元の出力ディレクトリにも公開された URL にも当てる。** 引数が
`http://` / `https://` で始まれば引き、そうでなければ読む。手元で通ったものが
公開先で落ちたなら、落ちたのは組み立てではなく配信である — 切り分けが引数 1 つで
済むように、判定の側は 1 本にしてある。

**期待する一覧は台帳を持たず、面の入口から導く。** 入口に並べた記号がそのまま
「出ていなければならないもの」なので、別に一覧を書くと二重管理になる
([ADR-0001](../docs/decisions/0001-founding-principles.md) 原則 9)。入口を書き換え
れば期待も動く。

**中間の経路も見る。** 面の道具はモジュールのページしか作らないので、`/documentation/`
のような途中の階層には何も置かれない — URL を後ろから削って上へ行く読者はそこで
行き止まりになる ([#549](https://github.com/mokume-metal/mokume/issues/549))。手で被せた
1 枚が居ることと、その行き先が面のモジュールを指していることを、ここで一緒に見る。

**索引を 1 回引いて突き合わせる。** 記号 1 つずつを引くと公開先へ数十回の要求が
飛ぶうえ、判定の材料が「ページのファイルがあるか」に落ちる — 面の目次に現れない
ページでも「出ている」と数えてしまう。索引は面の目次そのものなので、これを材料に
すれば**読者が辿り着ける形で出ているか**まで一度に見られる。
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# 読み口は site_source が持つ (#815)。**手元の組み上げにも公開先にも同じ読み口で当てる**
# ので、写しを持つと「手元では通るが公開先だけ落ちる」が起きる
from site_source import (  # noqa: E402
    Source,
    Unreachable,
    landing_of,
)

# 中間の 1 枚が指す行き先の**名前の節**。`url=mokume/` / `href="mokume/"` /
# `<link rel="canonical" href="mokume/">` の 3 つの綴りから、同じ 1 つの名前を取り出す。
#
# **substring では見たことにならない** ([#1101](https://github.com/mokume-metal/mokume/issues/1101))。
# 以前は `module.lower() not in middle.lower()` で見ていたが、この 1 枚は SPDX ヘッダ・
# 題・リンクの文字列にも面の名前を持つので、**行き先を架空の名前へ変えても判定は真に
# ならなかった**。名前が `MokumeCore` だった頃は `mokumecore` が他の理由で現れないので
# 効いていた判定が、名前を `mokume` へ短くした瞬間に空回りへ変わっている — 検査が守る
# 対象そのものが検査を無効化した形である。
MIDDLE_TARGET = re.compile(
    r"""(?:url=|href=["'])\.?/?([A-Za-z0-9_.-]+)/""", re.IGNORECASE)

# Topics に並べた行 (`- ` の後に二重バッククォートの記号が 1 つだけの行)。
# **中身の形を問わずにまず全部拾う** — 形で絞って拾うと、知らない形の行は期待から黙って落ち、出ていなくても誰も言わない
# (索引が型の粒度だった頃は口 1 本の形が現れなかった・#582。引数の型で区別した形も
# 同じ落ち方をしていた・#2672)。拾った行は下の 2 つの形に読み分け、どちらでもない行は名乗る
CURATED_ROW = re.compile(r"^\s*-\s*``([^`\n]+)``\s*$", re.MULTILINE)

# 経路そのものの形。入れ子は `Foo/Bar` の形で書けるので `/` を、口 1 本は `Foo/bar(_:_:)`
# の形になるので括弧・コロン・同名を分けるハッシュの印 (`-9jeha`) も含む。経路は小文字に
# 畳めば公開の索引の経路と一致する
PATH_SYMBOL = re.compile(r"[A-Za-z_][A-Za-z0-9_/(:)-]*")

# 引数の型で区別した形 (`Foo/fill(_:_:)-(Color,_)`)。公開の経路はこの形ではなく
# ハッシュの形 (`fill(_:_:)-108zr`) で出るので、経路と文字列では突き合わせられない。
# **索引の各ノードの題 (`func fill(Color, some ScalarConvertible)`) が引数の型を持つ**
# ので、基底 (`Foo/fill(_:_:)`) の下の頁のうち、題の引数の並びが行と合うものを引く (#2672)
TYPED_SYMBOL = re.compile(r"([A-Za-z_][A-Za-z0-9_/(:)]*\))-\((.*)\)")

# 引数 1 つの綴りのうち、目次の型の形が書かないもの。題は `with: Color`・
# `some ScalarConvertible` と書き、目次は `Color`・`ScalarConvertible` と書く
PARAMETER_LABEL = re.compile(r"^\s*(?:[A-Za-z_]\w*\s+)?[A-Za-z_]\w*\s*:(?!:)")
PARAMETER_NOISE = re.compile(
    r"@\w+(?:\([^)]*\))?|\b(?:some|any|inout|borrowing|consuming|sending|__owned|__shared)\b|\s+"
)


def typed_parts(symbol: str) -> tuple[str, list[str]] | None:
    """引数の型で区別した形なら (基底, 引数の型の並び) を、そうでなければ None を返す。"""
    if match := TYPED_SYMBOL.fullmatch(symbol):
        types = split_top_level(match.group(2))
        if types is not None:
            return match.group(1), [normalize_parameter(t) for t in types]
    return None


def split_top_level(text: str) -> list[str] | None:
    """括弧の外の `,` で分ける。括弧の対が合わなければ None。空なら空の並び。"""
    parts: list[str] = []
    depth = 0
    current = ""
    for at, char in enumerate(text):
        if char in "([<":
            depth += 1
        elif char in ")]" or (char == ">" and text[at - 1:at] != "-"):
            depth -= 1
            if depth < 0:
                return None
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    if depth != 0:
        return None
    if current.strip() or parts:
        parts.append(current)
    return parts


def normalize_parameter(text: str) -> str:
    return PARAMETER_NOISE.sub("", PARAMETER_LABEL.sub("", text, count=1))


def title_parameters(title: str | None, name: str) -> list[str] | None:
    """索引の題 (`func fill<T>(with: Color) throws -> T`) から引数の型の並びを読む。

    名前の後の総称の節を飛ばし、最初の括弧の対の中身を取る。返り値や投げる節は見ない。
    読めなければ None。
    """
    if not title:
        return None
    match = re.search(rf"(?<![\w.]){re.escape(name)}(?![\w])", title)
    if match is None:
        return None
    at = match.end()
    if title[at:at + 1] == "<":
        depth = 0
        while at < len(title):
            if title[at] == "<":
                depth += 1
            elif title[at] == ">" and title[at - 1] != "-":
                depth -= 1
                if depth == 0:
                    at += 1
                    break
            at += 1
    if title[at:at + 1] != "(":
        return None
    depth = 0
    for end in range(at, len(title)):
        if title[end] == "(":
            depth += 1
        elif title[end] == ")":
            depth -= 1
            if depth == 0:
                parts = split_top_level(title[at + 1:end])
                return None if parts is None else [normalize_parameter(p) for p in parts]
    return None


def resolve_typed(
    root: str, symbol: str, published: dict[str, str | None]
) -> tuple[str | None, str | None]:
    """型の形の行が指す頁を引く。(引いた経路, 引けなかった理由) のどちらか一方を返す。

    基底の下の頁 (`<基底>` か `<基底>-<印>`) のうち、題の引数の並びが行と合うものが
    ちょうど 1 本なら引けたとする。`_` は何にでも当たる。
    """
    parts = typed_parts(symbol)
    assert parts is not None, symbol  # 呼ぶ側が型の形だと確かめてから渡す
    base, wanted = parts
    stem = f"{root}/{base.lower()}"
    name = base.rsplit("/", 1)[-1].split("(", 1)[0]
    candidates = sorted(
        path for path in published
        if path == stem or (path.startswith(f"{stem}-") and "/" not in path[len(stem):])
    )
    if not candidates:
        return None, f"入口に並べた ``{symbol}`` のページ ({stem} とその重なり) が出ていない"
    matched: list[str] = []
    unreadable: list[str] = []
    for path in candidates:
        parameters = title_parameters(published[path], name)
        if parameters is None:
            unreadable.append(path)
        elif len(parameters) == len(wanted) and all(
            want == "_" or want == got for want, got in zip(wanted, parameters)
        ):
            matched.append(path)
    if len(matched) == 1:
        return matched[0], None
    if len(matched) > 1:
        return None, (
            f"入口に並べた ``{symbol}`` が重なり {len(matched)} 本 ({', '.join(matched)}) に"
            "当たる — どの頁を並べたのかが決まらない (型を書き足して 1 本に絞る)"
        )
    if unreadable:
        return None, (
            f"入口に並べた ``{symbol}`` の重なりを引けない — 索引の題から引数の並びを読めない頁が"
            f"ある ({', '.join(unreadable)})"
        )
    return None, (
        f"入口に並べた ``{symbol}`` のページが出ていない — {stem} の重なり "
        f"({', '.join(candidates)}) のどれも引数の型が合わない"
    )


def expectations(catalog: pathlib.Path) -> tuple[str, list[str], list[str], list[str]]:
    """(モジュール名, 入口に並べた記号, 読めない行, 記事のファイル名) を面の入口から導く。"""
    landing, module = landing_of(catalog)
    text = landing.read_text(encoding="utf-8")
    symbols: list[str] = []
    unreadable: list[str] = []
    for row in CURATED_ROW.findall(text):
        if typed_parts(row) is not None or PATH_SYMBOL.fullmatch(row):
            symbols.append(row)
        else:
            unreadable.append(row)
    articles = [p.stem for p in sorted(catalog.glob("*.md")) if p != landing]
    return module, symbols, unreadable, articles


def paths_in_index(index: dict) -> dict[str, str | None]:
    """索引に載っている経路すべてと、その題。言語ごとの木を平らに畳む。

    題は引数の型で区別した行を重なりの単位で引くのに要る (#2672)。
    """
    found: dict[str, str | None] = {}

    def walk(nodes: list[dict]) -> None:
        for node in nodes:
            if path := node.get("path"):
                found[path] = found.get(path) or node.get("title")
            walk(node.get("children") or [])

    for roots in (index.get("interfaceLanguages") or {}).values():
        walk(roots)
    return found


def check(source: Source, catalog: pathlib.Path) -> list[str]:
    module, symbols, unreadable, articles = expectations(catalog)

    # **読めない行は黙って落とさず名乗る** (#2672)。落とした行は期待から消え、その頁が
    # 出ていなくても誰も言わない — 赤にして、読み口を広げるか行の書き方を変えるかを迫る
    unread = [
        f"入口の ``{row}`` は読めない形の行 — 出ているかを見ていない "
        "(経路の形か、引数の型で区別した形 `-(…)` で書く。別の形が要るなら "
        "scripts/check-published-reference.py の読み口を広げる)"
        for row in unreadable
    ]

    # **記号が 0 件なら通してはいけない。** 入口の書式が変わって拾えなくなった状態が
    # 「全部出ている」と同じ緑で表れるのを防ぐ (check-docs-links.py と同じ守り)
    # 早い段で止まるときも読めない行は一緒に名乗る。隠れると、直した後の 2 回目で初めて出る
    if not symbols:
        return unread + [f"面の入口 ({catalog}) から記号を 1 つも読み取れない — 検査が成立していない"]

    metadata = source.read_json("metadata.json")
    if metadata is None:
        return unread + [f"{source.target} に metadata.json が無い — 参照の面として組み上がっていない"]
    bundle = (metadata.get("bundleDisplayName") or "").lower()
    if not bundle:
        return unread + [f"{source.target} の metadata.json に bundleDisplayName が無い"]

    index = source.read_json("index/index.json")
    if index is None:
        return unread + [f"{source.target} に索引 (index/index.json) が無い"]
    published = paths_in_index(index)

    problems: list[str] = list(unread)

    root = f"/documentation/{module.lower()}"
    if root not in published:
        problems.append(f"モジュールの面 {root} が索引に無い")

    page = source.read_json(f"data{root}.json")
    if page is None:
        problems.append(f"モジュールの面の中身 (data{root}.json) が無い")
    elif page.get("metadata", {}).get("title") != module:
        problems.append(
            f"data{root}.json の題が {page.get('metadata', {}).get('title')!r} で、{module!r} ではない"
        )

    # 静的な置き場としてそのまま配れる形になっているか。ページごとの index.html が
    # 無いと、公開先では経路がそのまま 404 になる
    if source.read(f"documentation/{module.lower()}/index.html") is None:
        problems.append(
            f"documentation/{module.lower()}/index.html が無い — 静的配信の形に変換されていない"
        )

    # **中間の経路も行き止まりにしない** (#549)。道具はモジュールのページしか作らない
    # ので、`/documentation/` には手で被せた 1 枚が要る。**その行き先まで見る** — 手で
    # 書いた行き先はモジュールの名前が変われば黙って腐り、症状は「上の階層へ行くと
    # 404」でビルドは緑のままである
    middle = source.read("documentation/index.html")
    if middle is None:
        problems.append(
            "documentation/index.html が無い — 面の中間の経路 (/documentation/) が行き止まりになる"
        )
    else:
        targets = {
            match.group(1).lower()
            for match in MIDDLE_TARGET.finditer(middle.decode("utf-8", errors="replace"))
        }
        if not targets:
            problems.append(
                "documentation/index.html に面への行き先が 1 つも無い "
                "(綴りが変わって拾えていない可能性)"
            )
        elif targets != {module.lower()}:
            stray = ", ".join(sorted(targets - {module.lower()})) or "(無し)"
            problems.append(
                f"documentation/index.html が {module} 以外を指している ({stray}) — "
                "モジュールの名前が変わったまま行き先が取り残されている"
            )

    # 入口の行が指す頁の経路。逆向きの判定もこれで突き合わせる
    curated_paths: set[str] = set()
    for symbol in symbols:
        if typed_parts(symbol) is not None:
            # 型の形は、題の引数の並びで重なりを 1 本に引く。基底の下に頁が 1 つでも
            # 居れば通すと、重なりの片方が消えても残った方で緑になる (#2672)
            resolved, reason = resolve_typed(root, symbol, published)
            if resolved is None:
                problems.append(reason)
            else:
                curated_paths.add(resolved)
            continue
        path = f"{root}/{symbol.lower()}"
        curated_paths.add(path)
        if path not in published:
            problems.append(f"入口に並べた ``{symbol}`` のページ ({path}) が出ていない")

    # 記事はモジュールではなくカタログの名前の下に出る (実測)。**期待するのは入口に
    # 並べた記事だけ**である — 並べていない記事も道具が既定の `Articles` の束へ拾って
    # 出しはするが (ADR-0027「測ったこと」)、それは誰も出ているかを見ていない記事で、
    # ここで期待に数えると「入口から辿れる形になっているか」を見なくなる
    for article in articles:
        path = f"/documentation/{bundle}/{article.lower()}"
        if path not in published:
            problems.append(f"記事 {article}.md のページ ({path}) が出ていない")

    # **逆向きも見る** (#515)。ここまでは「並べたものが出ているか」だけを見ていて、
    # 新しい公開型を足して入口に並べ忘れても何も起きなかった — 道具が既定の束
    # (`Structures` / `Enumerations` …) へ自動で入れるので、面には出るし検査も緑になる。
    # 読者から見ると、その型だけが意味の無い束の底に落ちる
    prefix = f"{root}/"
    tops = {
        path[len(prefix):]
        for path in published
        if path.startswith(prefix) and "/" not in path[len(prefix):]
    }
    # 型の形で並べた最上位は、引いた頁の経路で数える。基底で突き合わせると、1 行で
    # 同じ基底の重なりが全部「並べてある」になる (#2672)
    curated = {path[len(prefix):] for path in curated_paths if path.startswith(prefix)}
    forgotten = sorted(tops - curated)
    if forgotten:
        problems.append(
            "面に出ているのに入口に並んでいない最上位: "
            + ", ".join(forgotten)
            + " (入口の Topics へ足すか、読者が書く人でないなら Makefile の "
            "REFERENCE_OMIT で面から外す)"
        )

    print(
        f"見た先: {source.target}\n"
        f"  モジュール: {module} / カタログ: {bundle}\n"
        f"  索引に載っている経路: {len(published)}\n"
        f"  入口に並べた記号: {len(symbols)} / 記事: {len(articles)}\n"
        f"  面に出ている最上位: {len(tops)} (並べ漏れ {len(forgotten)})"
    )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="組み上がった面のディレクトリ、または公開された URL")
    parser.add_argument(
        "--catalog",
        type=pathlib.Path,
        default=pathlib.Path("Documentation/mokume.docc"),
        help="面の入口を持つカタログ (既定: Documentation/mokume.docc)",
    )
    arguments = parser.parse_args()

    if not arguments.catalog.is_dir():
        print(f"カタログが無い: {arguments.catalog}", file=sys.stderr)
        return 1

    try:
        problems = check(Source(arguments.target), arguments.catalog)
    except Unreachable as unreachable:
        # **「出ていない」ではなく「読めなかった」。** 混ぜると直す先を間違える
        # (入口の書き方を直すのか、配信を直すのか)。向きは site_source の冒頭が持つ
        print(f"参照の面を検められない — {unreachable}", file=sys.stderr)
        return 1

    if problems:
        print("参照の面に出ていないものがある:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\n入口 (カタログの ``Module`` を題にした .md) から辿れる形になっているかを見る。"
            "変換が成功しても出ていないことはある — 題より前に 1 行あるだけで、"
            "そのページの説明と Topics は丸ごと落ちる。",
            file=sys.stderr,
        )
        return 1

    print("ok: 入口に並べたものは全部出ていて、面に出ている最上位はすべて入口に並んでいる")
    return 0


if __name__ == "__main__":
    sys.exit(main())
