#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""公開 API の一覧を組み立て、名前と面の規範に沿っているかを検査する。

## 一覧はリポジトリへ置かない

生成物をリポジトリへ置くと、**それが古くないことを守る検査**が要るようになり、以後
すべての変更がその検査に引っかかる。置かずに要るときだけ組み立てれば、そのクラスの
検査ごと不要になる (ADR-0001 原則 8)。だから出力先は必ず引数で受け取り、既定値を
持たない。

## 数えるのは生成側の仕事

**件数を文書へ直書きしない。** 直書きした数は API が増えた瞬間に嘘になり、しかも
嘘になったことが誰にも分からない。数える必要があるものはここから出す。

その直書きを見張る側は `scripts/tests/written_counts_test.py` にある (#819)。判定は
`*.md` を読むだけでシンボルグラフを使わないので、ここに置くとドキュメントだけ直した
PR までパッケージのフル再ビルド (`api: build`) を待つことになる。

材料はコンパイラが出すシンボルグラフで、ソースの見た目ではない。公開されているかの
判定を自前の構文解析に持たせると、ソースの書き方が変わるたびに判定が狂う。

**唯一の例外がコメントの本文である。** シンボルグラフの `docComment` に載るのは `///`
だけで、`//` は載らない。載らないものを「説明文が無い」と読むと、`/` を 1 本削るだけで
説明文の検査から消えられる (#315 で実際にそうなっていた)。だから宣言の直前に書かれた
文字はソースから読む — ただし**どこが公開宣言か**も**どこにあるか**もグラフの側から取り、
ソースから読むのは `location` が指した行の直前だけに留める。
"""

from __future__ import annotations

import argparse
import functools
import json
import pathlib
import re
import sys
import urllib.parse

# 利用者が最初に触る層。ここだけ手本 (Processing / p5) の綴りが正になる (ADR-0020 決定 1)
ENTRY_TYPE = "Sketch"
# 転送先の層。ここは常に Swift の慣行が正
LOWER_TYPE = "Canvas"

KIND_ORDER = [
    "swift.protocol",
    "swift.class",
    "swift.struct",
    "swift.enum",
]


def load_requirements(graphs: pathlib.Path, module: str) -> set[str]:
    """プロトコルの要件と、その既定の実装。転送先ではないので、対称性の検査から外す。"""
    requirements: set[str] = set()
    for path in sorted(graphs.glob("*.symbols.json")):
        name = path.name.split(".symbols.json")[0]
        if name != module and not name.startswith(f"{module}@"):
            continue
        document = json.loads(path.read_text(encoding="utf-8"))
        for relationship in document.get("relationships", []):
            if relationship.get("kind") in {"requirementOf", "defaultImplementationOf"}:
                requirements.add(relationship["source"])
    return requirements


def load_symbols(graphs: pathlib.Path, module: str) -> list[dict]:
    """モジュールのシンボルを読む。拡張のぶんは別ファイルに出るのでまとめて拾う。

    **他所の宣言から写された手続きは落とす。** 標準ライブラリの型を 1 つ拡張すると、
    その型が準拠している約束ごとの既定の実装まで、こちらの拡張のグラフへ
    `::SYNTHESIZED::` の印つきで並ぶ (`Int` を拡張しただけで `Int.formatted(_:)` が
    出てくる)。自分たちが書いた面ではないので、一覧にも載せないし境界の検査にも掛けない。
    """
    symbols: list[dict] = []
    for path in sorted(graphs.glob("*.symbols.json")):
        name = path.name.split(".symbols.json")[0]
        if name != module and not name.startswith(f"{module}@"):
            continue
        document = json.loads(path.read_text(encoding="utf-8"))
        for symbol in document.get("symbols", []):
            if symbol.get("accessLevel") != "public":
                continue
            if "::SYNTHESIZED::" in symbol["identifier"]["precise"]:
                continue
            symbols.append(symbol)
    # プロトコルの要件と既定の実装は同じ名前で 2 度出る。一覧では 1 つに畳む。
    # **引数の型まで見て畳む** — 名前だけで畳むと、同名で引数型の違う宣言が 1 本に
    # 潰れる。潰れたぶんは一覧から落ち、説明文の検査からも隠れる (#315)
    unique: dict[tuple[str, str, tuple[str, ...]], dict] = {}
    for symbol in symbols:
        unique.setdefault((owner(symbol), title(symbol), signature(symbol)), symbol)
    return list(unique.values())


def own_modules(graphs: pathlib.Path) -> set[str]:
    """このパッケージが組み上げたモジュールの名前。

    グラフのファイル名がそのまま名乗りになっている (`<モジュール>.symbols.json` と、
    拡張のぶんの `<モジュール>@<拡張した型のモジュール>.symbols.json`)。読む対象を
    名前の表で持たないのは、モジュールが増えた日に書き足し忘れないため。
    """
    return {path.name.split(".symbols.json")[0].split("@")[0] for path in graphs.glob("*.symbols.json")}


def load_owned_identifiers(graphs: pathlib.Path) -> set[str]:
    """このパッケージが定義するシンボルの識別子。閉包の検査の「自前」の定義になる。

    モジュール名をマングリングから読み取らずグラフの中身を数えるのは、判定を
    コンパイラの出力そのものに預けるため (このスクリプト全体の作法)。読む対象は
    一覧に載るモジュールだけではない — 別のモジュールの型が公開の署名に漏れたら、
    それは一覧に載りようがない型なので、同じく問題として上げたい。
    """
    identifiers: set[str] = set()
    for path in sorted(graphs.glob("*.symbols.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        for symbol in document.get("symbols", []):
            identifiers.add(symbol["identifier"]["precise"])
    return identifiers


def declaration(symbol: dict) -> str:
    return "".join(fragment["spelling"] for fragment in symbol.get("declarationFragments", []))


def signature(symbol: dict) -> tuple[str, ...]:
    """引数の型の並び。同名の宣言を見分ける鍵になる (`background(_:)` は 2 本ある)。"""
    parameters = (symbol.get("functionSignature") or {}).get("parameters", [])
    types: list[str] = []
    for parameter in parameters:
        spelling = "".join(
            fragment.get("spelling", "") for fragment in parameter.get("declarationFragments", []))
        types.append(spelling.split(":", 1)[-1].strip())
    return tuple(types)


def doc(symbol: dict) -> str:
    """宣言に付いた説明文。`///` は `docComment` に載り、`//` はソースから読む。

    2 つを 1 つの入口にまとめてあるのは、**書き方の違いで検査の視界が変わらない**ように
    するためである。`//` へ落として検査から消えるなら、それは規範ではなく抜け道になる。
    """
    lines = (symbol.get("docComment") or {}).get("lines", [])
    written = "\n".join(line.get("text", "") for line in lines).strip()
    return written or slash_doc(symbol)


@functools.lru_cache(maxsize=None)
def source_lines(path: str) -> tuple[str, ...]:
    return tuple(pathlib.Path(path).read_text(encoding="utf-8").split("\n"))


def slash_doc(symbol: dict) -> str:
    """宣言の直前に積まれた `//` の塊。`///` が付いていれば空を返す (そちらが正)。"""
    location = symbol.get("location")
    if not location:
        return ""
    path = urllib.parse.unquote(urllib.parse.urlparse(location["uri"]).path)
    try:
        lines = source_lines(path)
    except OSError:
        return ""
    index = location.get("position", {}).get("line", 0) - 1
    block: list[str] = []
    while 0 <= index < len(lines):
        text = lines[index].strip()
        if text.startswith("@"):  # 属性は宣言の一部。またいで上を見る
            index -= 1
            continue
        if text.startswith("///"):
            return ""
        if text.startswith("//"):
            block.append(text[2:].strip())
            index -= 1
            continue
        break
    return "\n".join(reversed(block)).strip()


def owner(symbol: dict) -> str:
    path = symbol.get("pathComponents", [])
    return path[0] if len(path) > 1 else ""


def title(symbol: dict) -> str:
    return symbol.get("names", {}).get("title", "")


# ---------------------------------------------------------------- 一覧


def render(symbols: list[dict], version: str) -> str:
    by_owner: dict[str, list[dict]] = {}
    top: list[dict] = []
    for symbol in symbols:
        if owner(symbol):
            by_owner.setdefault(owner(symbol), []).append(symbol)
        else:
            top.append(symbol)

    out: list[str] = []
    out.append(f"# mokume {version} の公開 API")
    out.append("")
    out.append(
        f"公開シンボル {len(symbols)} 個 / 型 {len(top)} 個。"
        "この一覧は版ごとに組み立てたもので、リポジトリには置かれていない。"
    )
    out.append("")

    def sort_key(symbol: dict) -> tuple:
        kind = symbol["kind"]["identifier"]
        rank = KIND_ORDER.index(kind) if kind in KIND_ORDER else len(KIND_ORDER)
        return (rank, title(symbol))

    for parent in sorted(top, key=sort_key):
        name = title(parent)
        out.append(f"## {name}")
        out.append("")
        summary = doc(parent).split("\n")[0]
        if summary:
            out.append(summary)
            out.append("")
        out.append("```swift")
        out.append(declaration(parent))
        for member in sorted(by_owner.get(name, []), key=title):
            out.append("    " + declaration(member))
        out.append("```")
        out.append("")

    orphans = sorted(set(by_owner) - {title(s) for s in top})
    if orphans:
        out.append("## その他")
        out.append("")
        out.append("```swift")
        for parent in orphans:
            for member in sorted(by_owner[parent], key=title):
                out.append(f"{parent}.{declaration(member)}")
        out.append("```")
        out.append("")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- 検査

ONOFF_PREFIXES = ("enable", "disable", "clear")


def check_onoff(symbols: list[dict]) -> list[str]:
    """ADR-0020 決定 2: オンオフは 1 系統で表す。

    対になる綴りを許すと「どちらの系統かを予測する規則」が無くなる。前身では凍結の
    直前に 4 系統が併存していた。
    """
    problems = []
    for symbol in symbols:
        name = title(symbol).split("(")[0]
        for prefix in ONOFF_PREFIXES:
            if name.startswith(prefix) and len(name) > len(prefix) and name[len(prefix)].isupper():
                problems.append(
                    f"{owner(symbol) or '(トップレベル)'}.{title(symbol)}: "
                    f"`{prefix}*` の綴りはオンオフの系統を増やす (ADR-0020 決定 2)。"
                    "手本があれば手本の綴り、無ければ真偽値を 1 つ取る関数を 1 本置く"
                )
    return problems


def check_forwarding(symbols: list[dict], requirements: set[str]) -> list[str]:
    """ADR-0020 決定 1: 下の層が上の層の転送先なら、同じ名前・同じ引数ラベルを保つ。

    ずれると、上で書けたコードが下で書けない (逆も然り) という食い違いが、
    型の上では見えないまま入る。
    """
    entry = {
        title(s): s
        for s in symbols
        if owner(s) == ENTRY_TYPE and s["identifier"]["precise"] not in requirements
    }
    lower = {title(s): s for s in symbols if owner(s) == LOWER_TYPE}
    lower_bases: dict[str, set[str]] = {}
    for name in lower:
        lower_bases.setdefault(name.split("(")[0], set()).add(name)

    problems = []
    for name in sorted(entry):
        base = name.split("(")[0]
        if base not in lower_bases or name in lower:
            continue
        problems.append(
            f"{ENTRY_TYPE}.{name} と {LOWER_TYPE}.{sorted(lower_bases[base])[0]} で"
            "引数ラベルが食い違う (ADR-0020 決定 1: 転送の対称性)"
        )
    return problems


def check_doc_canon(symbols: list[dict]) -> list[str]:
    """ADR-0020 決定 4 / ADR-0001 原則 9: 説明文の正本は、利用者が最初に触る層に置く。

    同じ説明を 2 か所に置けば必ず食い違い、その食い違いは**生成した一覧を通して
    エージェントの書くコードに届く**。

    突き合わせは名前だけでなく引数の型まで見る。名前だけで組にすると、同名の宣言が
    複数あるとき (`background(_:)`) どれと比べたかが行き当たりばったりになる (#315)。
    """
    entry = {(title(s), signature(s)): s for s in symbols if owner(s) == ENTRY_TYPE}
    lower = {(title(s), signature(s)): s for s in symbols if owner(s) == LOWER_TYPE}

    problems = []
    for key, symbol in sorted(entry.items()):
        twin = lower.get(key)
        if twin is None:
            continue
        name = key[0]
        upper_doc, lower_doc = doc(symbol), doc(twin)
        if not lower_doc:
            continue
        if upper_doc and lower_doc == upper_doc:
            problems.append(
                f"{name}: 同じ説明文が {ENTRY_TYPE} と {LOWER_TYPE} の両方にある "
                "(ADR-0020 決定 4: 正本は 1 層)"
            )
        elif upper_doc and len(lower_doc) > len(upper_doc):
            problems.append(
                f"{name}: {LOWER_TYPE} 側の説明文が {ENTRY_TYPE} 側より長い "
                "(ADR-0020 決定 4: 下の層には転送であることだけを書く)"
            )
    return problems


def check_type_closure(symbols: list[dict], owned: set[str]) -> list[str]:
    """一覧に載る宣言の署名に出てくる型は、その一覧の中に居なければならない (#326)。

    落ちていると、一覧だけを読む相手は引数を組み立てられず「一覧はあるのに書けない」
    になる。同型の実装で実際に踏んだ穴で、#219 のコメントに記録がある。

    載っているべきなのは**このパッケージが定義する型**だけ。stdlib や Foundation の
    型はこの一覧の外に正典があるので対象外で、その線引きを `owned` が引く — 許可
    リストを手で持たない (持てば、外の型が増えるたびに書き足す仕事が生まれる)。
    """
    listed = {symbol["identifier"]["precise"] for symbol in symbols}

    problems = []
    for symbol in symbols:
        seen: set[str] = set()
        for fragment in symbol.get("declarationFragments", []):
            identifier = fragment.get("preciseIdentifier")
            if identifier is None or identifier in listed or identifier in seen:
                continue
            seen.add(identifier)
            if identifier not in owned:
                continue
            problems.append(
                f"{owner(symbol) or '(トップレベル)'}.{title(symbol)}: "
                f"署名に出てくる {fragment.get('spelling', identifier)} が一覧に無い。"
                "一覧だけを読む相手はこの宣言を呼べない (#326)"
            )
    return problems


# 外の型を面に出してよいシンボルと、その理由 (ADR-0020 決定 6)。
#
# 作法は `scripts/check-no-binaries.sh` の ALLOWLIST と同じ — **対象と理由を組で書く**。
# モジュール単位で丸ごと許さないのは、一度許すと以後その語彙が何本出ても検査が黙るため
# である。ここへ 1 行足すたびに判断が入るのが狙いで、書けるのは「その型でなければ表せない
# 理由」に限る (「便利だから」は理由にならない)。
FOREIGN_ALLOWLIST = {
    "OutputFrame.texture": "毎フレーム絵を渡す出口へ、描画資源をそのまま手渡す一点 (ADR-0024 決定 8)。包むと受け取る側が取り出す口を別に求め、露出の点が増える",
    "PNGFile.write(_:to:)": "書き出し先の指定。ファイルの場所の正典は標準ライブラリの外にある",
    "RenderDevice.init(device:)": "既に持っている Metal の資源を持ち込む入口。意図して開けてある",
    "RenderTarget.writePNG(to:)": "書き出し先の指定 (PNGFile.write と同じ理由)",
    "Shader.url": "読み込み元の在処。読んだファイルを指し直せる形で返す",
    "SketchRuntime.renderFrame(to:)": "書き出し先の指定 (PNGFile.write と同じ理由)",
    "WorkDirectory.base": "作業場所の在処。WorkDirectory は場所そのものを扱う型なので URL が本体",
    "WorkDirectory.facet(_:)": "作業場所の下位を指す (WorkDirectory.base と同じ理由)",
    "WorkDirectory.given": "環境から受け取った作業場所 (WorkDirectory.base と同じ理由)",
    "WorkDirectory.given(environment:)": "環境から受け取った作業場所 (WorkDirectory.base と同じ理由)",
    "WorkDirectory.root": "作業場所の根 (WorkDirectory.base と同じ理由)",
    "WorkDirectory.root(under:)": "基準を外から渡す形の根 (WorkDirectory.base と同じ理由)",
    "WorkDirectory.facet(_:under:)": "基準を外から渡す形の区画 (WorkDirectory.base と同じ理由)",
    "SharedFrameWindow.init(gpu:facet:title:)": "見張っているスケッチ側の区画を指す。道具は自分の作業場所ではなくそこへ置くので、場所を渡す口が要る (WorkDirectory.facet と同じ理由)",
    "SharedFramePreview.init(gpu:facet:params:title:)": "作品の窓と同じ区画を独立に見るプレビューと、つまみの区画 (SharedFrameWindow.init と同じ理由)",
}


def module_of(identifier: str) -> str:
    """USR からモジュール名を取る。

    マングリングの読み取りをここ 1 か所に閉じる。Swift の USR は
    `s:<長さ><モジュール名>...` の形で自分の由来を名乗り、標準ライブラリだけは短縮されて
    `s:S...` / `s:s...` になる。ObjC から来た型は `c:objc(...)` で、モジュール名を持たない。
    """
    if identifier.startswith("c:objc("):
        return "(ObjC)"
    if identifier.startswith("s:S") or identifier.startswith("s:s"):
        return "Swift"
    matched = re.match(r"^s:(\d+)(.*)$", identifier)
    if matched:
        return matched.group(2)[: int(matched.group(1))]
    return "(不明)"


def check_foreign_vocabulary(
    symbols: list[dict], owned: set[str], own: set[str] = frozenset()
) -> list[str]:
    """公開の署名に出てよいのは、自前の型と Swift 標準ライブラリだけ (ADR-0020 決定 6)。

    `check_type_closure` と同じ材料を**逆向きに**見る。あちらは自前の型が一覧から落ちて
    いないか (閉包)、こちらは外の型が一覧に入り込んでいないか (境界) を見る。どちらも
    「一覧だけを読む相手がその宣言を呼べるか」を守っている — 落ちていても、外の語彙で
    書かれていても、一覧は呼べないものを呼べる顔で並べることになる。

    見つかったものは既定で落とす。正当な例外は `FOREIGN_ALLOWLIST` に理由つきで載せる。

    自分たちのモジュールに属する識別子は外の語彙ではない。宣言されたシンボルとして
    数えられないもの (総称の仮引数など) がここで外来と誤って挙がっていた。
    """
    problems = []
    for symbol in symbols:
        name = f"{owner(symbol) or '(トップレベル)'}.{title(symbol)}"
        if name in FOREIGN_ALLOWLIST:
            continue
        seen: set[str] = set()
        for fragment in symbol.get("declarationFragments", []):
            identifier = fragment.get("preciseIdentifier")
            if identifier is None or identifier in owned or identifier in seen:
                continue
            seen.add(identifier)
            module = module_of(identifier)
            if module == "Swift" or module in own:
                continue
            problems.append(
                f"{name}: 署名に {module} の {fragment.get('spelling', identifier)} が出ている。"
                "外の語彙は版ごとに配る一覧を通して利用者とエージェントに届く "
                "(ADR-0020 決定 6)。自前の型で表すか、"
                "scripts/api-surface.py の FOREIGN_ALLOWLIST に理由つきで載せる"
            )
    return problems


# ---------------------------------------------------------------- 入口


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["list", "check"])
    parser.add_argument("--graphs", required=True, type=pathlib.Path)
    parser.add_argument("--module", default="MokumeCore")
    parser.add_argument("--version", default="(開発版)")
    parser.add_argument("--output", type=pathlib.Path)
    arguments = parser.parse_args()

    symbols = load_symbols(arguments.graphs, arguments.module)
    if not symbols:
        print(
            f"シンボルグラフが見つからない: {arguments.graphs} に "
            f"{arguments.module}.symbols.json が要る",
            file=sys.stderr,
        )
        return 1

    if arguments.action == "list":
        text = render(symbols, arguments.version)
        if arguments.output:
            arguments.output.write_text(text, encoding="utf-8")
            print(f"ok: {arguments.output} に公開シンボル {len(symbols)} 個を書いた")
        else:
            sys.stdout.write(text)
        return 0

    owned = load_owned_identifiers(arguments.graphs)
    problems = (
        check_onoff(symbols)
        + check_forwarding(symbols, load_requirements(arguments.graphs, arguments.module))
        + check_doc_canon(symbols)
        + check_type_closure(symbols, owned)
        + check_foreign_vocabulary(symbols, owned, own_modules(arguments.graphs))
    )
    if problems:
        print("公開 API が規範に沿っていない:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"ok: 公開シンボル {len(symbols)} 個が規範に沿っている")
    return 0


if __name__ == "__main__":
    sys.exit(main())
