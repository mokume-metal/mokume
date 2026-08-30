#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""参照の面へ渡すシンボルグラフを集め、面の名前を名乗らせる (#561)。

**面の URL と、ページに出るモジュール名を決めるのはシンボルグラフの `module.name`
である。** カタログの名前ではない ([ADR-0027](../docs/decisions/0027-readable-surfaces.md)
決定 1・決定 3)。何も手を入れなければ、そこに入るのは**ターゲット名** — つまり
[ADR-0016](../docs/decisions/0016-package-structure.md) の層の割り方の産物であって、
面の名前として選ばれたものではない。実際 `MokumeCore` がそのまま URL に出て、面の
入口は「この面の題になっている `MokumeCore` は〜」と言葉で埋めることになっていた。

ADR-0027 決定 1 は既に「**面に何が出るかを、ビルドの副産物に決めさせない**」と定めて
いる。この道具は同じ規律を**名前**へ延長する — 面に出すモジュールを名指しするのと同じ
場所で、面が名乗る名前も名指しする。

## なぜアンブレラのシンボルグラフをそのまま渡さないのか (実測)

利用者が書くのは `import mokume` の 1 行なので、アンブレラ (`Sources/mokume/`) の
グラフを渡せば名前は自然に `mokume` になる。**ならない。** 手元 (Xcode 26 同梱の docc)
で測ると、`@_exported import` の再エクスポートはグラフの上で 2 方向に壊れる:

- **Darwin の記号が 341 ページ漏れる。** `acos` / `cbrt` / `DBL_MAX` … が面に並ぶ。
  三角関数 7 本の名指し再エクスポート ([#193](https://github.com/mokume-metal/mokume/issues/193))
  の副産物で、一覧の側が踏んだのと同じ現象である
- **逆に 6 記号が面から落ちる。** `Inlet` / `Outlet` / `Plugin` / `PluginRegistry` /
  `StartupReads` / `OutputFrame` — いずれも `MokumeCore` のグラフには居るのに、
  アンブレラのグラフには載らない

**アンブレラの意味は正しく、それを運ぶ道具が壊れている。** だからここでは意味だけを
迂回して実現する — 実体のグラフ (`MokumeCore`) を、利用者が `import` する名前で
名乗らせる。書き換え後の名前は実在する公開モジュール名であって、作り出した名前ではない。

## 書き換えるのは、読者に名前として見える 2 欄だけ

- `module.name` — 面の URL とページのモジュール表示になる
- 各記号の `swiftExtension.extendedModule` — **ただし面の内側を指しているものだけ**

**2 つ目を見落とすと、面の内側の拡張が「よそのモジュールの拡張」に化ける。**
`module.name` だけを書き換えると、拡張の記号は「`mokume` が `MokumeCore` の型を拡張
している」という形になり、docc は `metadata.extendedModule` と `relatedModules` を
書き出す — 手元で測ると **329 ページ**が読者に `MokumeCore` を見せていた。面の中の
拡張は面の名前で名乗らせる。**よそ (Swift 等) を指す `extendedModule` は触らない** —
そちらは本当によそのモジュールの拡張である。

**それ以外は触らない。** `identifier.precise` のマングル名 (`s:10MokumeCore…`) も
`externalID` もそのままにする — 記号の同一性はコード上の実体を指したままでよく、
読者には見えない。

この 2 欄を揃えた出力は、**現行と 1 ページも警告も違わない** (938 ページ・警告 16 本。
手元で実測)。変わるのは URL とページ上のモジュール表示だけになる。

## 面から外す型 (ADR-0027 決定 5)

面の相手は**スケッチを書く人 1 種類**である。道具・エージェント・実行の土台だけが触る型は
`--omit` で名指しして外す。**`public` は 1 つも動かさない** — 落とすのはここを通るグラフ
だけなので、一覧 (`api-surface.py`) も ADR-0020 の検査もビルドが出したグラフを見たままで、
道具・拡張・エージェントは今までどおり使える。

`@_documentation(visibility: internal)` は採らない。**効きすぎる** — ソースに 1 行足すと
ビルドが出すグラフから消えるので、同じグラフを使う一覧と検査からも同時に消える。人が読む面
だけに効かせられない。

**外す基準は人が名指しする。** 起点からの到達可能性で自動判定にはしない — 索引を人が意味で
束ねる以上、意味ではなく型の到達で線を引くと「`mouseX` は出るが `InputState` は消える」の
ような、読者に説明できない切り方になる。名指しの綴りがずれたら落とす (下記)。

## モジュールが増えたら

**同じ面の名前を名乗る複数のグラフは、1 つの面にマージされる** (実測: 2 本渡して
938 → 940 ページ・警告は増えず)。利用者から見た入口を 1 つに保つ ADR-0016 決定 2 と
同じ形に素直に伸びるので、増えたときにこの道具の形を変える必要は無い。

**出力のファイル名は元のモジュール名のままにする。** 名前を書き換えたぶんファイル名まで
揃えると、2 本目以降が 1 本目を上書きして面が黙って痩せる。docc が見るのは中身の
`module.name` だけで、ファイル名は見ない。

## 名指ししたものが無ければ落ちる

面が痩せた状態は、変換が成功し警告も出ないまま「そのページだけが存在しない」として
現れる (ADR-0027 が繰り返し踏んでいる壊れ方)。ここで落としておけば、少なくとも
「渡すはずのものが渡っていない」は組み立ての時点で分かる。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


def graphs_of(source: pathlib.Path, module: str) -> list[pathlib.Path]:
    """モジュール 1 つ分のグラフ。本体と、拡張のグラフ (`M@Other.symbols.json`)。"""
    return sorted(
        path
        for path in source.glob("*.symbols.json")
        if path.name == f"{module}.symbols.json" or path.name.startswith(f"{module}@")
    )


def place(
    path: pathlib.Path,
    surface: str,
    inside: set[str],
    omit: set[str],
    destination: pathlib.Path,
) -> tuple[int, int, set[str]]:
    """グラフを、面の名前を名乗らせて置く。(書き換えた拡張, 外した記号, 外した型の名前)。

    `inside` は面に集めるモジュールの名前。**そこに載っているものだけを面の内側**と
    見なし、拡張の名乗りも面の名前へ寄せる。

    `omit` は面から外す最上位の型の名前。**`public` は 1 つも動かさない** — ここで
    落とすのは人が読む面へ渡すグラフだけで、一覧 (`api-surface.py`) と ADR-0020 の検査は
    ビルドが出したグラフをそのまま見たままになる。型ごと落とすので、その型に属する
    記号 (メンバー・入れ子) も一緒に落ちる。
    """
    graph = json.loads(path.read_text(encoding="utf-8"))
    graph["module"]["name"] = surface

    dropped: set[str] = set()
    omitted: set[str] = set()
    kept = []
    for symbol in graph.get("symbols", []):
        components = symbol.get("pathComponents") or []
        if components and components[0] in omit:
            dropped.add(symbol["identifier"]["precise"])
            omitted.add(components[0])
            continue
        kept.append(symbol)
    graph["symbols"] = kept

    # **記号を落としたら、それを指す関係も落とす。** 残すと docc は居ない記号への辺を
    # 辿り、面の形が壊れる (親を失ったメンバーが根に浮く)
    graph["relationships"] = [
        relationship
        for relationship in graph.get("relationships", [])
        if relationship.get("source") not in dropped and relationship.get("target") not in dropped
    ]

    extensions = 0
    for symbol in graph["symbols"]:
        swift_extension = symbol.get("swiftExtension")
        if swift_extension and swift_extension.get("extendedModule") in inside:
            swift_extension["extendedModule"] = surface
            extensions += 1

    destination.write_text(json.dumps(graph), encoding="utf-8")
    return extensions, len(dropped), omitted


def main() -> int:
    parser = argparse.ArgumentParser(
        description="参照の面へ渡すシンボルグラフを集め、面の名前を名乗らせる"
    )
    parser.add_argument(
        "--graphs", type=pathlib.Path, required=True, help="ビルドが出したグラフの置き場"
    )
    parser.add_argument("--out", type=pathlib.Path, required=True, help="docc へ渡す置き場")
    parser.add_argument(
        "--surface", required=True, help="面が名乗る名前 (利用者が import する名前)"
    )
    parser.add_argument(
        "--module", nargs="+", required=True, dest="modules", help="面に出すモジュール"
    )
    parser.add_argument(
        "--omit",
        nargs="*",
        default=[],
        dest="omitted",
        help="面から外す最上位の型 (道具・実行の土台が触るもの。ADR-0027 決定 5)",
    )
    arguments = parser.parse_args()

    if not arguments.graphs.is_dir():
        print(f"グラフの置き場が無い: {arguments.graphs}", file=sys.stderr)
        return 1

    arguments.out.mkdir(parents=True, exist_ok=True)

    inside = set(arguments.modules)
    omit = set(arguments.omitted)
    placed: list[str] = []
    missing: list[str] = []
    extensions = 0
    dropped = 0
    omitted: set[str] = set()
    for module in arguments.modules:
        found = graphs_of(arguments.graphs, module)
        if not found:
            missing.append(module)
            continue
        for path in found:
            renamed, removed, seen = place(
                path, arguments.surface, inside, omit, arguments.out / path.name
            )
            extensions += renamed
            dropped += removed
            omitted |= seen
            placed.append(path.name)

    # **外すと名指ししたものが 1 つも無ければ落とす。** 綴りがずれたまま通すと、外した
    # つもりの型が黙って面に出る — 出ているのは正しい形に見えるので、気付く手掛かりが無い
    unknown = sorted(omit - omitted)
    if unknown and not missing:
        print(
            f"面から外すと名指しした型がグラフに無い: {', '.join(unknown)}",
            file=sys.stderr,
        )
        print("  綴りが実体とずれているか、その型が既に公開されていない。", file=sys.stderr)
        return 1

    if missing:
        print(
            f"面に出すと名指ししたモジュールのグラフが無い: {', '.join(missing)}",
            file=sys.stderr,
        )
        print(
            f"  探した先: {arguments.graphs}\n"
            "  ビルドの出力にそのモジュールが無いか、名指しの綴りが実体とずれている。",
            file=sys.stderr,
        )
        return 1

    print(
        f"面の名前: {arguments.surface} / 渡すグラフ {len(placed)} 本: {', '.join(placed)}\n"
        f"  面の内側を指す拡張を名乗り直した: {extensions} 件\n"
        f"  面から外した型: {len(omitted)} 本 / 記号 {dropped} 件"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
