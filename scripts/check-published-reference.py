#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""参照の面に、置いたものが実際に出ているかを見る (#478)。

**この道具が塞ぐのは「置いても出ない」である。** 面を組み立てる道具は、入力に
入らなかった素材について何も言わないことがある — 変換は成功し、警告も出ず、
出力にだけ存在しない。ビルドの緑は「出ている」を意味しないので、**組み上がった
ものを引いて中身を確かめる**経路を別に持つ (ADR-0027 決定 1)。

**同じ判定を、手元の出力ディレクトリにも公開された URL にも当てる。** 引数が
`http://` / `https://` で始まれば引き、そうでなければ読む。手元で通ったものが
公開先で落ちたなら、落ちたのは組み立てではなく配信である — 切り分けが引数 1 つで
済むように、判定の側は 1 本にしてある。

**期待する一覧は台帳を持たず、面の入口から導く。** 入口に並べた記号がそのまま
「出ていなければならないもの」なので、別に一覧を書くと二重管理になる
([ADR-0001](../docs/decisions/0001-founding-principles.md) 原則 9)。入口を書き換え
れば期待も動く。

**索引を 1 回引いて突き合わせる。** 記号 1 つずつを引くと公開先へ数十回の要求が
飛ぶうえ、索引に載っていない (どこからも辿れない) ページを「出ている」と誤って
数える。索引は面の目次そのものなので、これを材料にすれば「置いたのに辿れない」も
同じ判定で落ちる。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

# 入口の見出し `# ``MokumeCore``` — カタログの中でモジュールの面を上書きするファイル
LANDING_TITLE = re.compile(r"^#\s*``([A-Za-z_][A-Za-z0-9_]*)``\s*$", re.MULTILINE)
# Topics に並べた記号 (``Foo``)。入れ子の型は `Foo/Bar` の形で書けるので `/` も拾う
CURATED_SYMBOL = re.compile(r"^\s*-\s*``([A-Za-z_][A-Za-z0-9_/]*)``\s*$", re.MULTILINE)

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

    def read_json(self, relative: str) -> dict | None:
        raw = self.read(relative)
        return json.loads(raw.decode("utf-8")) if raw is not None else None


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

    for symbol in symbols:
        path = f"{root}/{symbol.lower()}"
        if path not in published:
            problems.append(f"入口に並べた ``{symbol}`` のページ ({path}) が出ていない")

    # 記事はモジュールではなくカタログの名前の下に出る (実測)。**入口から辿れない
    # 記事は索引に載らない**ので、置いただけで満足していないかがここで分かる
    for article in articles:
        path = f"/documentation/{bundle}/{article.lower()}"
        if path not in published:
            problems.append(f"記事 {article}.md のページ ({path}) が出ていない")

    print(
        f"見た先: {source.target}\n"
        f"  モジュール: {module} / カタログ: {bundle}\n"
        f"  索引に載っている経路: {len(published)}\n"
        f"  入口に並べた記号: {len(symbols)} / 記事: {len(articles)}"
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
            "置いただけの文と記号は、変換が成功しても出力に現れない。",
            file=sys.stderr,
        )
        return 1

    print("ok: 入口に並べたものは全部出ている")
    return 0


if __name__ == "__main__":
    sys.exit(main())
