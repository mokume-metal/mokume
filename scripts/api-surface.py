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


def diagnose_empty(graphs: pathlib.Path, module: str) -> str:
    """読むシンボルが 1 つも無かった理由。**出ていないのか中身が違うのかを分ける** (#1308)。

    以前はどの状態でも「シンボルグラフが見つからない」の 1 文だった。その文面は置き場が
    無いときにも、グラフは出ているのに公開シンボルが 0 個のときにも同じことを言うので、
    打った人は次に何を直すのか分からない — [#1291](https://github.com/mokume-metal/mokume/issues/1291)
    (置き場を相対パスで渡すとグラフが 1 本も出ない) を追うときも、まず「置き場が無いのか、
    出ていないのか」の切り分けから始めることになった。

    返すのは 2 行 — 1 行目で何が無いかを名乗り、2 行目で探した先と読み方を言う。形は
    `scripts/reference-graphs.py` の診断に揃えているが、**文面は共有しない** (割れても
    変わるのは出力の文面で、その場で目に見える — ADR-0008 決定 6)。

    どのファイルをモジュール 1 つと数えるかは `own_modules` に預ける。ここで自分で
    名前を照合すると、判定が読む範囲と診断が言う範囲が別々に動きうる。
    """
    if not graphs.is_dir():
        return (
            f"シンボルグラフの置き場が無い: {graphs}\n"
            "  ビルドが出した置き場を渡していない (Makefile の SYMBOL_GRAPHS)"
        )
    modules = own_modules(graphs)
    if not modules:
        return (
            f"シンボルグラフが 1 本も出ていない: {graphs} に *.symbols.json が無い\n"
            "  ビルドが成功しても、-emit-symbol-graph-dir の行き先が失われるとこうなる (#1291)"
        )
    if module not in modules:
        return (
            f"{module} のシンボルグラフが無い: {graphs} にあるのは {', '.join(sorted(modules))}\n"
            "  --module の綴りが実体とずれているか、そのモジュールがビルドに含まれていない"
        )
    return (
        f"{module} のシンボルグラフに公開シンボルが 1 つも無い: 読んだ先は {graphs}\n"
        "  グラフは出ている — 中身が空か、public な宣言が 1 つも無い"
    )


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


def order(symbol: dict) -> tuple[str, tuple[str, ...]]:
    """一覧に並べる順 (#880)。

    **`title` だけを鍵にすると、同名オーバーロードは全部同じ鍵になる。** Python の
    `sorted` は安定なので、同じ鍵の中ではシンボルグラフの順序 = ソースの並び順が
    そのまま残り、**公開 API を 1 つも変えていないのに一覧が動く** (#797 で 8 行動いた)。
    この一覧は版ごとのリリース資産なので、版の間で diff したときに並び替えがノイズになる。

    割るのは `signature` — 引数の型の並びで、同名の宣言を見分ける鍵として既に
    畳み込みの判定が使っているものである。
    """
    return (title(symbol), signature(symbol))


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
        for member in sorted(by_owner.get(name, []), key=order):
            out.append("    " + declaration(member))
        out.append("```")
        out.append("")

    orphans = sorted(set(by_owner) - {title(s) for s in top})
    if orphans:
        out.append("## その他")
        out.append("")
        out.append("```swift")
        for parent in orphans:
            for member in sorted(by_owner[parent], key=order):
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
    "BundledShaders.location": "同梱の原文の在処。切り分けの口 (mokume doctor) が「どこから読んでいるか」を名乗るために要る — 読めるかどうかだけでは、配った形が成立しているかを分けられない (Shader.url と同じ理由)",
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
    "WorkDirectory.requestURL(under:)": "区画の中の要求ファイルの在処。綴りを 1 箇所に保つには、場所を組んで返すしかない (WorkDirectory.base と同じ理由)",
    "WorkDirectory.reportURL(under:)": "区画の中の応答ファイルの在処 (WorkDirectory.requestURL と同じ理由)",
    "WorkDirectory.directoryExists(at:)": "見に行く場所の指定。返すのではなく受けるだけなので PNGFile.write(_:to:) と同じ向きで、在処の正典は標準ライブラリの外にある",
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


# 参照スケッチ。作者向けの面は、絵か操作で示せるものをすべてここから呼ぶ (#1350)
SKETCHES = pathlib.Path(__file__).resolve().parents[1] / "Sketches"

# 参照スケッチから呼ばなくてよい `Sketch` の公開メンバ (基底名)。表の出どころは #1350 の
# 「対象から外すもの」。**書けるのは「スケッチでは示せない理由」に限る** — 足すのが面倒な
# だけのものを載せると、#1358 が塞いだ空白がここへ移るだけになる
UNSHOWN = {
    "save": "結果が絵ではなくファイルで、--render のたびにファイルが書かれる。正しさはテストが見る",
    "beginRecord": "save と同じ理由 (記録の書き出し)",
    "endRecord": "save と同じ理由 (記録の書き出し)",
    "plugins": "作者が書くのは 1 行だけで、中身は外のパッケージが書く",
    "loadShader": "ファイルから読む口で、見どころの「ファイルを直すと変わる」は自己完結したスケッチでは示せない",
    "loadComputation": "loadShader と同じ理由",
    "loadEffect": "loadShader と同じ理由",
    "usesFrameHistory": "--render の「同じ番号のフレームは同じ絵」を崩す",
    "main": "入口は Sketches/main.swift が持つ",
}


def check_sketch_coverage(
    symbols: list[dict], sources: str, unshown: dict[str, str] = UNSHOWN
) -> list[str]:
    """`Sketch` の公開メンバが、参照スケッチのどこかで呼ばれているか (#1358)。

    機能を足す PR は検査と説明文の例までは揃えるが、参照スケッチへ足すことを求める
    ものが無く、100 件を超える空白が溜まった (#1350)。空白は不具合も隠す — スケッチから
    呼べる場所の無い口が、スケッチへ足すまで誰にも見つからなかった (#1367)。

    見るのは基底名 (引数部を落とした名前) の字面で、列挙の case までは見ない。コメントは
    落としてから照合するが、**文字列の中に書いた名前は「呼ばれた」に数える** — 取り
    こぼすのは名前を文字列にだけ書いたときで、そこまでは追わない。
    """
    code = re.sub(r"/\*.*?\*/", "", sources, flags=re.DOTALL)
    code = re.sub(r"//[^\n]*", "", code)
    bases = {title(s).split("(")[0] for s in symbols if owner(s) == ENTRY_TYPE}
    problems = []
    for base in sorted(bases - unshown.keys()):
        if re.search(rf"(?<![A-Za-z0-9_]){re.escape(base)}(?![A-Za-z0-9_])", code):
            continue
        problems.append(
            f"{ENTRY_TYPE}.{base} が参照スケッチ (Sketches/) から呼ばれていない。"
            "絵か操作で示せるなら参照スケッチから呼ぶ。示せないなら、その理由を添えて "
            "scripts/api-surface.py の UNSHOWN に載せる (#1358)"
        )
    return problems


# 公開の口が何の仕事をするかの種類 (#1670)。**寿命の約束 (ADR-0021 決定 4) は種類ごとに
# 決まっている**ので、口を足したらまず種類を決める。
#
# | 種類 | 何か | フレームの外で呼ぶと |
# | --- | --- | --- |
# | 描き方 | どう描くかの状態 (塗り・線・読み方・文字・貼る絵・種…) | 効く。フレームを越えて残る |
# | シーンの記述 | 何を描くかの状態 (視点・投影・光・材質・変換・影・周囲・効果・切り抜き) | 警告して無視する |
# | 図形 | 絵を置く (頂点を並べて形を置く口も含む) | 持ち越しを約束する区間でだけ置ける (#1603 の決定。R3 の根が扱う) |
# | 読み取り | 値を返すだけで、絵もフレームの状態も変えない | 読める |
# | 資源 | 作る・読み込む (返したものは寿命を持たない) | 作れる |
# | 組み立て | スケッチとフレームの組み立て (入口・進行・作者が書くコールバック・書き出し・観測) | 口ごとに決まる |
#
# **シーンの記述は、フレームの外で呼ぶと注意が出るかを口ごとに回す検査に名前が要る**
# (`check_port_kinds`)。守りは口ごとの `guard isDrawing` で、書き落とした口が黙る —
# 変換 (#941)・切り抜き (#1505)・効果 (#1605)・`noLights()` (#1670) を 1 件ずつ見つけてきた。
#
# 分類の正典は Documentation/mokume.docc/mokume.md の「状態の寿命」と ADR-0021 決定 4 の表。
# **表だけでは決まらない口は、理由を組で書く** (FOREIGN_ALLOWLIST・UNSHOWN と同じ作法)。
# 鍵は基底名 (引数部を落とした名前) で、`Sketch` と `Canvas` の同名の口は同じ行を引く。
DRAWING_STYLE = "描き方"
SCENE = "シーンの記述"
FIGURE = "図形"
READING = "読み取り"
RESOURCE = "資源"
ASSEMBLY = "組み立て"
PORT_KIND_NAMES = (DRAWING_STYLE, SCENE, FIGURE, READING, RESOURCE, ASSEMBLY)

PORT_KINDS: dict[str, str | tuple[str, str]] = {
    # 描き方 — 表の「塗り・線の色と太さ・端と折れ目の形・混ぜ方・座標の読み方・文字の設定・
    # 絵に掛ける色・貼る絵・断片・断片が読む数の並び・揺らぎの種と細かさ・露出」
    "fill": DRAWING_STYLE,
    "noFill": DRAWING_STYLE,
    "stroke": DRAWING_STYLE,
    "noStroke": DRAWING_STYLE,
    "strokeWeight": DRAWING_STYLE,
    "strokeCap": DRAWING_STYLE,
    "strokeJoin": DRAWING_STYLE,
    "blendMode": DRAWING_STYLE,
    "rectMode": DRAWING_STYLE,
    "ellipseMode": DRAWING_STYLE,
    "imageMode": DRAWING_STYLE,
    "textFont": DRAWING_STYLE,
    "noTextFont": DRAWING_STYLE,
    "textSize": DRAWING_STYLE,
    "textAlign": DRAWING_STYLE,
    "textLeading": DRAWING_STYLE,
    "textStyle": DRAWING_STYLE,
    "textWrap": DRAWING_STYLE,
    "tint": DRAWING_STYLE,
    "noTint": DRAWING_STYLE,
    "texture": DRAWING_STYLE,
    "noTexture": DRAWING_STYLE,
    "shader": DRAWING_STYLE,
    "resetShader": DRAWING_STYLE,
    "numbers": DRAWING_STYLE,
    "resetNumbers": DRAWING_STYLE,
    "noiseSeed": DRAWING_STYLE,
    "noiseDetail": DRAWING_STYLE,
    "exposure": DRAWING_STYLE,
    "toneMapping": (DRAWING_STYLE, "表には露出だけがある。同じ画面の明るさの段 (Brightness) の設定で、画面が持ち越す"),
    "curveDetail": (DRAWING_STYLE, "表に無い。曲線の頂点の細かさで、線の太さと同じくスタイルとして持ち越す"),
    "curveTightness": (DRAWING_STYLE, "curveDetail と同じ理由"),
    "randomSeed": (DRAWING_STYLE, "表の「揺らぎの種」と同じく、乱数の流れの種で持ち越す"),
    "orbit": (DRAWING_STYLE, "視点を操る道具の状態で、フレームを越えて持ち越す (setup() で書く例がある)。視点そのものを書くのは orbitControl"),
    # シーンの記述 — 表の「視点・投影・光・材質・変換・影・周囲の光・効果・切り抜き」
    "camera": SCENE,
    "setCamera": SCENE,
    "perspective": SCENE,
    "ortho": SCENE,
    "orbitControl": (SCENE, "Sketch にだけある口。中で視点 (camera) を書く"),
    "ambientLight": SCENE,
    "directionalLight": SCENE,
    "pointLight": SCENE,
    "spotLight": SCENE,
    "lights": SCENE,
    "noLights": (SCENE, "光を取り除く口。フレームの外には取り除く光が無いが、書いたことは知らせる (noClip の #970 と同じ)"),
    "ambient": SCENE,
    "emissive": SCENE,
    "metalness": SCENE,
    "shininess": SCENE,
    "translate": SCENE,
    "rotate": SCENE,
    "rotateX": SCENE,
    "rotateY": SCENE,
    "rotateZ": SCENE,
    "scale": SCENE,
    "shearX": SCENE,
    "shearY": SCENE,
    "applyMatrix": SCENE,
    "resetMatrix": SCENE,
    "pushMatrix": SCENE,
    "popMatrix": SCENE,
    "pushStyle": (SCENE, "描き方を積むが、積んだ履歴はフレームに属する (ADR-0021 決定 4 の 2026-09-06 の追補・#925)"),
    "popStyle": (SCENE, "pushStyle と同じ理由"),
    "push": (SCENE, "変換とスタイルの両方を積む (pushMatrix と pushStyle)"),
    "pop": (SCENE, "push と同じ理由"),
    "shadows": SCENE,
    "shadowRange": SCENE,
    "shadowDetail": SCENE,
    "shadowBias": SCENE,
    "castShadow": SCENE,
    "receiveShadow": SCENE,
    "surroundings": SCENE,
    "effects": SCENE,
    "clip": SCENE,
    "noClip": SCENE,
    "particles": (SCENE, "表に無い。フレームの中でだけ扱い、外では注意して無視する (Canvas.isShaping の説明が挙げる「粒」)。1 フレーム進めるので、置くだけの図形とは寿命が違う"),
    "force": (SCENE, "particles と同じ理由"),
    "emit": (SCENE, "particles と同じ理由。Sketch にだけある口"),
    "compute": (SCENE, "表に無い。描く前の段としてフレームの中でだけ走り、外では注意して無視する (ADR-0023 決定 3・Canvas.isShaping の説明が挙げる「計算」)"),
    # 図形
    "arc": FIGURE,
    "background": FIGURE,
    "box": FIGURE,
    "circle": FIGURE,
    "cone": FIGURE,
    "cylinder": FIGURE,
    "ellipse": FIGURE,
    "ellipsoid": FIGURE,
    "image": FIGURE,
    "line": FIGURE,
    "model": FIGURE,
    "plane": FIGURE,
    "point": FIGURE,
    "quad": FIGURE,
    "rect": FIGURE,
    "shape": FIGURE,
    "sphere": FIGURE,
    "square": FIGURE,
    "text": FIGURE,
    "torus": FIGURE,
    "triangle": FIGURE,
    "set": (FIGURE, "画素の書き込み。#1603 の決定 (2b) で「置くこと」に含む"),
    "beginShape": FIGURE,
    "endShape": FIGURE,
    "beginContour": FIGURE,
    "endContour": FIGURE,
    "vertex": FIGURE,
    "bezierVertex": FIGURE,
    "quadraticVertex": FIGURE,
    "curveVertex": FIGURE,
    "normal": FIGURE,
    "index": FIGURE,
    # 読み取り
    "width": READING,
    "height": READING,
    "pixelWidth": READING,
    "pixelHeight": READING,
    "frameCount": READING,
    "time": READING,
    "deltaTime": READING,
    "mouseX": READING,
    "mouseY": READING,
    "pmouseX": READING,
    "pmouseY": READING,
    "dragX": READING,
    "dragY": READING,
    "scrollX": READING,
    "scrollY": READING,
    "mouseButton": READING,
    "isMousePressed": READING,
    "key": READING,
    "keyCode": READING,
    "isKeyDown": READING,
    "get": READING,
    "loadPixels": READING,
    "pixels": (READING, "画素の窓を返す。窓からの書き込みは set と同じく #1603 の R3 が扱う"),
    "read": READING,
    "noise": READING,
    "random": (READING, "値を返す。種は randomSeed が持つ"),
    "screenX": READING,
    "screenY": READING,
    "screenZ": READING,
    "spacePosition": READING,
    "currentCamera": READING,
    "textWidth": READING,
    "textAscent": READING,
    "textDescent": READING,
    "textOutline": (READING, "文字の輪郭を値で返す。置くのは作者"),
    "usesFrameHistory": READING,
    "defaultSolidDetail": READING,
    "output": (READING, "描き先 (RenderTarget) を返す。作るのは面の組み立て"),
    # 資源
    "createGraphics": RESOURCE,
    "createImage": RESOURCE,
    "createShape": RESOURCE,
    "loadImage": RESOURCE,
    "requestImage": RESOURCE,
    "loadModel": RESOURCE,
    "requestModel": RESOURCE,
    "loadShader": RESOURCE,
    "makeShader": RESOURCE,
    "loadEffect": RESOURCE,
    "makeEffect": RESOURCE,
    "loadComputation": RESOURCE,
    "makeComputation": RESOURCE,
    "makeNumbers": RESOURCE,
    "makeParticles": RESOURCE,
    # 組み立て
    "init": ASSEMBLY,
    "main": ASSEMBLY,
    "settings": ASSEMBLY,
    "plugins": ASSEMBLY,
    "params": ASSEMBLY,
    "canvas": (ASSEMBLY, "Sketch から下の層 (Canvas) へ降りる口"),
    "setup": ASSEMBLY,
    "draw": ASSEMBLY,
    "loop": ASSEMBLY,
    "noLoop": ASSEMBLY,
    "redraw": ASSEMBLY,
    "beginDraw": ASSEMBLY,
    "endDraw": ASSEMBLY,
    "keyPressed": ASSEMBLY,
    "keyReleased": ASSEMBLY,
    "keyTyped": ASSEMBLY,
    "mousePressed": ASSEMBLY,
    "mouseReleased": ASSEMBLY,
    "mouseClicked": ASSEMBLY,
    "mouseMoved": ASSEMBLY,
    "mouseDragged": ASSEMBLY,
    "mouseWheel": ASSEMBLY,
    "save": (ASSEMBLY, "フレームの絵を外へ書き出す"),
    "beginRecord": (ASSEMBLY, "save と同じ理由"),
    "endRecord": (ASSEMBLY, "save と同じ理由"),
    "expose": (ASSEMBLY, "観測へ値を出す。絵にもフレームの状態にも触れない"),
    "measure": (ASSEMBLY, "expose と同じ理由 (かかった時間を出す)"),
}

# 「シーンの記述」の口を、口ごとにフレームの外で呼ぶ検査。**名前がここに字面で現れること**を
# `check_port_kinds` が求める
SCENE_TEST = (
    pathlib.Path(__file__).resolve().parents[1]
    / "Tests"
    / "MokumeCoreTests"
    / "SceneOutsideFrameTests.swift"
)


def port_kind(entry: str | tuple[str, str]) -> str:
    """表の 1 行から種類を取る。理由つきの行は (種類, 理由) の組で書く。"""
    return entry[0] if isinstance(entry, tuple) else entry


def check_port_kinds(
    symbols: list[dict], scene_test: str, kinds: dict[str, str | tuple[str, str]] = PORT_KINDS
) -> list[str]:
    """`Sketch` と `Canvas` の公開の口が種類の表に載り、シーンの記述は検査に名前があるか (#1670)。

    口ごとの `guard` で守る形は、書き落とした口が黙る。黙った口は 1 件ずつ見つかってきた
    (#941・#1505・#1605)。**範囲 (シーンの記述の口すべて) を回す検査**を置き、口を足したら
    種類を決めることと、シーンの記述ならその検査へ行を足すことを、ここが求める。

    照合は字面で、コメントは落としてから見る。`check_sketch_coverage` より狭く、**呼び出しの形
    (`$0.` / `canvas.` / `sketch.` に続く `名前(`) だけを数える** — 名前がどこかに出れば
    よい形では、断片の文字列の `values.scale`・列挙子の `.camera`・読んだ値の `style.clip` が
    行の代わりに数えられ、行を消しても緑のままだった (#1670 の反証)。

    **多重定義の数だけ呼び出しを求める。** 鍵は基底名なので、名前が 1 度出れば足りる形では、
    守りを書き落とした多重定義を足しても既存の行が名前を満たす (#1670 の反証)。数える
    多重定義は `Canvas` の側で (`Sketch` の口は転送なので同じ数になる)、`Canvas` に無い口
    だけ `Sketch` の側で数える。どの呼び出しがどの多重定義かまでは字面では見分けられない
    ので、見るのは数だけである。

    表に残った古い名前と、種類の綴り違いも上げる — どちらも黙って範囲を狭める。
    """
    code = re.sub(r"/\*.*?\*/", "", scene_test, flags=re.DOTALL)
    code = re.sub(r"//[^\n]*", "", code)
    overloads: dict[str, dict[str, int]] = {}
    for symbol in symbols:
        if owner(symbol) in {ENTRY_TYPE, LOWER_TYPE}:
            counts = overloads.setdefault(title(symbol).split("(")[0], {})
            counts[owner(symbol)] = counts.get(owner(symbol), 0) + 1
    bases = set(overloads)
    problems = []
    for base in sorted(bases - kinds.keys()):
        problems.append(
            f"{base} が公開の口の種類の表に無い。scripts/api-surface.py の PORT_KINDS に種類 "
            f"({' / '.join(PORT_KIND_NAMES)}) を決めて載せる。表だけでは決まらないなら理由を添える (#1670)"
        )
    for base in sorted(kinds.keys() - bases):
        problems.append(
            f"{base} は PORT_KINDS に載っているが、{ENTRY_TYPE} にも {LOWER_TYPE} にも公開の口が無い。"
            "表から外す (#1670)"
        )
    for base, entry in sorted(kinds.items()):
        kind = port_kind(entry)
        if kind not in PORT_KIND_NAMES:
            problems.append(f"{base} の種類「{kind}」は PORT_KIND_NAMES に無い (#1670)")
            continue
        if kind != SCENE or base not in bases:
            continue
        wanted = overloads[base].get(LOWER_TYPE) or overloads[base][ENTRY_TYPE]
        calls = len(re.findall(
            rf"(?<![A-Za-z0-9_])(?:\$0|canvas|sketch)\.{re.escape(base)}\s*\(", code))
        if calls >= wanted:
            continue
        problems.append(
            f"{base} はシーンの記述なのに、フレームの外で呼ぶと注意が出るかを見る検査 "
            f"({SCENE_TEST.name}) の呼び出しが {calls} 本で、多重定義 {wanted} 本に足りない。"
            "口ごとの表に行を足す (ADR-0021 決定 4・#1670)"
        )
    return problems


def read_sketches(directory: pathlib.Path) -> str:
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(directory.glob("*.swift"))
    )


# ---------------------------------------------------------------- 入口


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["list", "check"])
    parser.add_argument("--graphs", required=True, type=pathlib.Path)
    parser.add_argument("--module", default="MokumeCore")
    parser.add_argument("--version", default="(開発版)")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--sketches", default=SKETCHES, type=pathlib.Path)
    parser.add_argument("--scene-test", default=SCENE_TEST, type=pathlib.Path)
    arguments = parser.parse_args()

    symbols = load_symbols(arguments.graphs, arguments.module)
    if not symbols:
        print(diagnose_empty(arguments.graphs, arguments.module), file=sys.stderr)
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
        + check_sketch_coverage(symbols, read_sketches(arguments.sketches))
        + check_port_kinds(symbols, arguments.scene_test.read_text(encoding="utf-8"))
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
