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

# 読み口とタイムアウトは site_source が持つ (#815)。**この 3 本は必ず一緒に呼ばれる**
# ので、写しを持つと「手元では通るが公開先だけ落ちる」が起きる
from site_source import FETCH_TIMEOUT_SECONDS, Source  # noqa: E402,F401

# 入口の見出し `# ``MokumeCore``` — カタログの中でモジュールの面を上書きするファイル
LANDING_TITLE = re.compile(r"^#\s*``([A-Za-z_][A-Za-z0-9_]*)``\s*$", re.MULTILINE)
# Topics に並べた記号 (``Foo``)。入れ子は `Foo/Bar` の形で書けるので `/` を、口 1 本は
# `Foo/bar(_:_:)` の形になるので括弧・コロン・同名を分ける `-<印>` も拾う。
# **狭いと黙って見なくなる** — 並べたのに拾えなかった記号は期待から落ち、出ていなくても
# 誰も言わない (索引が型の粒度だった頃はこの形が現れなかった・#582)
CURATED_SYMBOL = re.compile(r"^\s*-\s*``([A-Za-z_][A-Za-z0-9_/(:)-]*)``\s*$", re.MULTILINE)

def landing_of(catalog: pathlib.Path) -> tuple[pathlib.Path, str]:
    """カタログの中の、モジュールの面を上書きするファイルとモジュール名。"""
    landings = []
    for path in sorted(catalog.glob("*.md")):
        match = LANDING_TITLE.search(path.read_text(encoding="utf-8"))
        if match:
            landings.append((path, match.group(1)))
    if len(landings) != 1:
        names = ", ".join(str(p) for p, _ in landings) or "(無し)"
        raise SystemExit(
            f"カタログ {catalog} のモジュールの入口が 1 つに決まらない: {names}\n"
            "記号を題にした .md (# ``Module``) がちょうど 1 つある形を期待している"
        )
    return landings[0]


def expectations(catalog: pathlib.Path) -> tuple[str, list[str], list[str]]:
    """(モジュール名, 入口に並べた記号, 記事のファイル名) を面の入口から導く。"""
    landing, module = landing_of(catalog)
    text = landing.read_text(encoding="utf-8")
    symbols = CURATED_SYMBOL.findall(text)
    articles = [p.stem for p in sorted(catalog.glob("*.md")) if p != landing]
    return module, symbols, articles


def paths_in_index(index: dict) -> set[str]:
    """索引に載っている経路すべて。言語ごとの木を平らに畳む。"""
    found: set[str] = set()

    def walk(nodes: list[dict]) -> None:
        for node in nodes:
            if path := node.get("path"):
                found.add(path)
            walk(node.get("children") or [])

    for roots in (index.get("interfaceLanguages") or {}).values():
        walk(roots)
    return found


def check(source: Source, catalog: pathlib.Path) -> list[str]:
    module, symbols, articles = expectations(catalog)

    # **記号が 0 件なら通してはいけない。** 入口の書式が変わって拾えなくなった状態が
    # 「全部出ている」と同じ緑で表れるのを防ぐ (check-docs-links.py と同じ守り)
    if not symbols:
        return [f"面の入口 ({catalog}) から記号を 1 つも読み取れない — 検査が成立していない"]

    metadata = source.read_json("metadata.json")
    if metadata is None:
        return [f"{source.target} に metadata.json が無い — 参照の面として組み上がっていない"]
    bundle = (metadata.get("bundleDisplayName") or "").lower()
    if not bundle:
        return [f"{source.target} の metadata.json に bundleDisplayName が無い"]

    index = source.read_json("index/index.json")
    if index is None:
        return [f"{source.target} に索引 (index/index.json) が無い"]
    published = paths_in_index(index)

    problems: list[str] = []

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
    elif module.lower() not in middle.decode("utf-8", errors="replace").lower():
        problems.append(
            f"documentation/index.html が {module} を指していない — "
            "モジュールの名前が変わったまま行き先が取り残されている"
        )

    for symbol in symbols:
        path = f"{root}/{symbol.lower()}"
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
    curated = {symbol.lower() for symbol in symbols if "/" not in symbol}
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

    problems = check(Source(arguments.target), arguments.catalog)
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
