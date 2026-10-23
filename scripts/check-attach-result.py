#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""作る口が `attach` の返す `false` を捨てていないかを見る (#2794)。

**塞ぐのは「足した本人にも、merge の前の検査にも壊れて見えない」形の再発である**。公開の
`attach(_:)` は、走っている実行の外から呼ばれたとき黙って `false` を返す。作る口 (音・通信・
カメラ・ゲームパッドの `createTCPServer` など) がそれを素で呼んで捨てると、足されていない入り口を
黙って返し、警告も利用者が呼んでいない `attach()` を名乗る。#2740 の反証でこれを指摘され、直した
翌日に、別の 2 本 (シリアル #2297・ゲームパッド #2295) が古い形を写して merge された。外で呼んだとき
の検査は口を手で並べたもので、新しい口を足しても赤くならなかった。

**だから作る口は、確かめて足すまでを 1 回で行う `package` の道具を通す** (`Sketch+Seams.swift` の
`attached(_:calledAs:making:)`・`attachedOnSurface(_:calledAs:making:)`・`attach(_:calledAs:returning:)`)。
足せなかった結果を捨てるのは、道具の中の 1 か所 (`attachAfterCheck`) だけにする。**ここで、道具を通さない
`attach` の呼び出し・参照をすべて赤にする。** 組み上げは要らない — 字句だけを読む
(`scripts/check-runtime-math.py` と同じ形)。

## 見るもの

- **対象は `Sources/` の下の Swift すべて** (除外する置き場は無い)。外のパッケージが足す口も、将来の
  `MokumeMIDI`・`MokumeGame` も同じ。置き場の名前の一覧を持たない
- **受け手の綴りを読まない。** 受け手を数える方式は `host.attach(pad)`・`part.attach(pad)` のように
  スケッチを引数で受け回す書き方、改行を挟んだ `sketch\\n.attach(pad)`、`?.`・添字・呼び出しの結果を受け手にした
  `engine?.attach(node)` を取り違えた。代わりに、**名前が `attach` の呼び出し・参照はすべて数える**:
  - 呼び出し: `attach(` の直後の引数を `)` まで読み、**トップレベルの引数のラベルに `calledAs` を持たなければ赤**
    (`attach(x, calledAs: …, returning: …)` だけが道具の形)。`attach(f(calledAs: c))` のように入れ子の中に
    あるだけでは道具の形ではない。改行・タブ・`self.`・`?.`・`[0].`・`()` を挟んでも同じ
  - 参照 (呼ばない): `inlets.forEach(attach)`・`let add = attach`・`= self.attach`・`` `attach`(x) `` も赤
- **数えないもの**: 宣言 (`func attach(`・`case attach`)・先頭のラベルが `_` でない呼び出し (`attach(to: view)`。
  スケッチの `attach` の第 1 引数はラベルが無いので、`to:` などで呼べるのは別の型の口)・受け手の無い `.attach` (列挙型の
  暗黙のメンバ)・`attach:` のラベル・コメントと文字列と正規表現リテラルの中。文字列補間 `\\(attach(x))` の中はコード
- **許すのは文脈で、引数の綴りではない**。`engine.attach(node)` (`AVAudioEngine`) のように Inlet・Outlet でない別の型の
  `attach` は、(ファイル, 型) の対で許す (`EXEMPT_TYPES`)。道具そのもの (`Sketch+Seams.swift` の `attach`・`attachAfterCheck`) は
  (ファイル, 関数) の対で許す (`EXEMPT_FUNCTIONS`)。引数名を変えても赤くならず、許した文脈の外に足した呼び出しは赤になる。
  **許可が空振りしたら (その型・関数がそのファイルに無ければ) 落とす** — 名前を変えたのに許可が残って、別の所を黙って
  許す形を防ぐ
- **投げる口 (`throws` の関数) の中の `attach(_:calledAs:returning:)` も赤**。この道具は投げない口のもので、外で呼ぶと
  `notRunning` を投げずに生きていない入り口を黙って返す。投げる口は `attached(_:calledAs:making:)` を通る
- **道具の置き場 (`MokumeCore/Sketch/Sketch+Seams.swift`) が道具の宣言を完全な形で持たなければ落とす**。
  `attached`・`attachedOnSurface` (`_ failure: …Type, calledAs …: String, making …`)・`attach(_ …, calledAs …, returning …)`
  の宣言を字句で読み、`func attachedAfterSurface` のような名前だけ似たものやコメントでは満たさない

字句の読みは `scripts/check-tool-language.py` の `blank_comments` を取り込んで使う
(`check-runtime-math.py` と同じ。写さない)。`blank_comments` は正規表現リテラルを知らないので、ここで
追って塗る (割り算と見分ける条件は `BARE_REGEX`)。

**見るのは作業ツリーで、git の木ではない** (#2016)。害がうるさい側 (手元だけ赤) だけで、CI の
木は作業ツリーの部分集合なので、逆向き (手元で緑・CI で赤) にはならない。

使い方: python3 scripts/check-attach-result.py [Sources のルート (既定 Sources)]
"""

import importlib.util
import re
import sys
from pathlib import Path

# 道具の置き場 (Sources のルートからの相対)
TOOLBOX = "MokumeCore/Sketch/Sketch+Seams.swift"
# 道具の宣言の完全な形 (字句)。名前だけ似たもの・コメントでは満たさない
TOOL_DECLARATIONS = {
    "attached(_:calledAs:making:)": re.compile(
        r"\bpackage\s+func\s+attached\s*<[^()]*>\s*\(\s*_\s+\w+\s*:\s*[\w.]+\s*,"
        r"\s*calledAs\s+\w+\s*:\s*String\s*,\s*making\s+\w+\s*:"),
    "attachedOnSurface(_:calledAs:making:)": re.compile(
        r"\bpackage\s+func\s+attachedOnSurface\s*<[^()]*>\s*\(\s*_\s+\w+\s*:\s*[\w.]+\s*,"
        r"\s*calledAs\s+\w+\s*:\s*String\s*,\s*making\s+\w+\s*:"),
    "attach(_:calledAs:returning:)": re.compile(
        r"\bpackage\s+func\s+attach\s*\(\s*_\s+\w+\s*:\s*any\s+Inlet\s*,"
        r"\s*calledAs\s+\w+\s*:\s*String\s*,\s*returning\s+\w+\s*:\s*String\s*\)"),
}

# 許す文脈 {Sources のルートからの相対: {名前: 理由}}。**引数の綴りでは許さない**
# 道具そのもの。足せなかった `false` を捨てるのは `attachAfterCheck` の 1 か所で、`attach` は公開の口と道具の本体
EXEMPT_FUNCTIONS = {
    TOOLBOX: {
        "attach": "公開の attach(_:) と道具 attach(_:calledAs:returning:) の本体が、走っている実行の attach へ渡す",
        "attachAfterCheck": "足せなかった false を捨てる 1 か所 (#2794)",
    },
}
# Inlet・Outlet でない別の型の同名の口
EXEMPT_TYPES = {
    "MokumeAudio/MicrophoneSource.swift": {
        "MicrophoneSource": "AVAudioEngine.attach(_:) で AVAudioSinkNode を繋ぐ",
    },
    "MokumeAudio/SoundFlow.swift": {
        "SoundFlow": "AVAudioEngine.attach(_:) で節を繋ぐ",
    },
    "MokumeNetwork/Datagram.swift": {
        "DatagramSender": "NWConnection を繋ぐ自分の attach(_:) (スケッチの attach ではない)",
    },
}

NAME = re.compile(r"(?<![\w$`])(?:`attach`|attach)(?![\w`])")
# 宣言の見出し。`.init(`・`@attached` は前の文字で除く
DECLARATION = re.compile(
    r"(?<![\w.@$`])(?P<kind>func|init|class|struct|enum|actor|extension|protocol)\b(?!\w)")
TYPE_KINDS = ("class", "struct", "enum", "actor", "extension", "protocol")
NOT_A_TYPE_NAME = {"func", "var", "let", "init", "subscript", "deinit", "override", "final", "static",
                   "public", "private", "package", "internal", "fileprivate", "open", "nonisolated", "mutating"}
# 見出しの途中でこれが出たら、本体の無い宣言 (プロトコルの要件など)
HEADER_STOPS = re.compile(r"(?<![\w.$`])(?:func|var|let|case|typealias|subscript|import)\b(?!\w)")
# 割り算 `a / b / c` と見分ける: 開く `/` の前が `(`・`,`・`=`・`:`・`[`・`{`・`!`・`&`・`|`・`?`・`<`・`>`・
# 行頭・`return`・`in` で、直後が空白・`/`・`*`・`=` でなく、同じ行で閉じ、閉じる `/` の前が空白でないもの
BARE_REGEX = re.compile(
    r"(?m)(?:^|[(,=:\[{!&|?<>]|\breturn\b|\bin\b)([ \t]*)(/(?![/*\s=])[^\n/]*[^\s/\n]/)")
EXTENDED_REGEX = re.compile(r"(#+)/[^\n]*?/\1")
LABEL = re.compile(r"\s*(?:(\w+)|(_))\s*:(?!:)")
LABEL_ONLY = re.compile(r"\s*(?:\w+|_)\s*:\s*")
IMPLICIT_AFTER = {"case", "return", "in", "else", "default", "if", "while", "switch", "where"}


def _blank_comments():
    """check-tool-language.py の字句の読みを取り込む (ファイル名にハイフンがあるので importlib)。"""
    path = Path(__file__).resolve().parent / "check-tool-language.py"
    spec = importlib.util.spec_from_file_location("check_tool_language", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.blank_comments


blank_comments = _blank_comments()


def blank_regex_literals(text):
    """正規表現リテラルの中身を空白で塗る (行番号は変わらない)。割り算は塗らない。"""
    def blank(match, group):
        start, end = match.span(group)
        return text[:start] + " " * (end - start) + text[end:]

    for pattern, group in ((EXTENDED_REGEX, 0), (BARE_REGEX, 2)):
        position = 0
        while True:
            match = pattern.search(text, position)
            if not match:
                break
            text = blank(match, group)
            position = match.end()
    return text


def code_of(text):
    """コメント・文字列の中身・正規表現リテラルを塗った写し。"""
    return blank_regex_literals(blank_comments(text, strings=True))


def matching(text, start, opening, closing):
    """`start` の `opening` に対応する `closing` の位置。閉じなければ None。"""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == opening:
            depth += 1
        elif text[index] == closing:
            depth -= 1
            if depth == 0:
                return index
    return None


def declarations(text):
    """宣言の並び: [{kind, name, start, body, end, header}]。本体の無い宣言は含めない。"""
    found = []
    for match in DECLARATION.finditer(text):
        kind = match.group("kind")
        rest = re.compile(r"\s*(`?[A-Za-z_][\w.]*`?)?").match(text, match.end())
        name = (rest.group(1) or "") if rest else ""
        if kind in TYPE_KINDS and (not name or name in NOT_A_TYPE_NAME):
            continue
        if kind == "init":
            name = "init"
        depth, index, body = 0, match.end() + (rest.end() - match.end() if rest else 0), None
        if kind == "init":
            index = match.end()
        while index < len(text):
            char = text[index]
            if char in "([":
                depth += 1
            elif char in ")]":
                depth -= 1
            elif depth == 0 and char == "{":
                body = index
                break
            elif depth == 0 and char in ";}":
                break
            elif depth == 0 and char.isalpha() and (index == 0 or not (text[index - 1].isalnum() or text[index - 1] in "_.$`")):
                if HEADER_STOPS.match(text, index):
                    break
            index += 1
        if body is None:
            continue
        end = matching(text, body, "{", "}")
        found.append({
            "kind": kind, "name": name.strip("`"), "start": match.start(), "body": body,
            "end": len(text) if end is None else end, "header": text[match.start():body]})
    return found


def innermost(decls, position, kinds):
    """`position` を含む宣言のうち、いちばん内側。"""
    best = None
    for decl in decls:
        if decl["kind"] in kinds and decl["start"] <= position <= decl["end"]:
            if best is None or decl["start"] > best["start"]:
                best = decl
    return best


def split_arguments(text, start):
    """`(` の直後 `start` から対応する `)` までを、トップレベルのコンマで分けた引数の綴り。閉じなければ None。"""
    depth, pieces, begin = 1, [], start
    for index in range(start, len(text)):
        char = text[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                pieces.append(text[begin:index])
                return pieces
        elif char == "," and depth == 1:
            pieces.append(text[begin:index])
            begin = index + 1
    return None


def label_of(argument):
    """引数の綴りの先頭のラベル。ラベルが無ければ None、`_` ならそのまま `_`。"""
    match = LABEL.match(argument)
    if not match:
        return None
    return match.group(1) or match.group(2)


def has_receiver(text, dot):
    """`dot` (`.` の位置) の前に受け手があるか。`(.attach)`・`case .attach` は暗黙のメンバで受け手が無い。"""
    index = dot - 1
    while index >= 0 and text[index].isspace():
        index -= 1
    if index < 0:
        return False
    if text[index].isalnum() or text[index] in "_$`":
        end = index
        while index >= 0 and (text[index].isalnum() or text[index] in "_$`"):
            index -= 1
        return text[index + 1:end + 1] not in IMPLICIT_AFTER
    return text[index] in ")]}?!>"


def classify(text, match):
    """`attach` の 1 か所を読む: (種類, 引数の綴り)。数えないものは (None, None)。

    種類は "bare" (道具を通さない呼び出し)・"reference" (呼ばない参照)・"tool" (`calledAs:` を持つ道具の形)。
    """
    start = match.start()
    before = text[max(0, start - 24):start]
    if re.search(r"\b(?:func|case|var|let)\s+$", before):
        return None, None
    index = start - 1
    while index >= 0 and text[index].isspace():
        index -= 1
    if index >= 0 and text[index] == "." and not has_receiver(text, index):
        return None, None
    after = match.end()
    while after < len(text) and text[after].isspace():
        after += 1
    nxt = text[after] if after < len(text) else ""
    if nxt == ":" and not text.startswith("::", after):
        return None, None
    if nxt != "(":
        return "reference", None
    pieces = split_arguments(text, after + 1)
    if pieces is None:
        return "bare", ""
    labels = [label_of(piece) for piece in pieces]
    # `attach(_:)`・`attach(_:calledAs:returning:)` は、引数ではなくラベルだけを並べた、呼ばない参照の綴り
    if pieces and all(LABEL_ONLY.fullmatch(piece) for piece in pieces):
        return ("tool" if "calledAs" in labels else "reference"), None
    if "calledAs" in labels:
        return "tool", " ".join(" ".join(pieces).split())
    first = labels[0] if labels else None
    if first not in (None, "_"):
        return None, None
    return "bare", " ".join(" ".join(pieces).split())


def findings(root):
    """(見た Swift の数, [(パス, 行番号, 種類, 引数の綴り, 行)], [空振りの許可の説明])。"""
    files = sorted(path for path in root.rglob("*.swift") if path.is_file())
    found, stale = [], []
    declared = {}
    for path in files:
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        original = text.splitlines()
        blanked = code_of(text)
        decls = declarations(blanked)
        declared[relative] = {(d["kind"] in TYPE_KINDS, d["name"]) for d in decls}
        for match in NAME.finditer(blanked):
            kind, spelled = classify(blanked, match)
            if kind is None:
                continue
            number = blanked.count("\n", 0, match.start()) + 1
            function = innermost(decls, match.start(), ("func", "init"))
            if kind == "tool":
                # 道具の形でも、投げる口の中では使えない (外で呼ぶと notRunning を投げずに黙って返す)
                if function and re.search(r"\bthrows\b", function["header"]):
                    found.append((path, number, "throwing", spelled, original[number - 1].strip()))
                continue
            if function and function["name"] in EXEMPT_FUNCTIONS.get(relative, {}):
                continue
            owner = innermost(decls, match.start(), TYPE_KINDS)
            if owner and owner["name"] in EXEMPT_TYPES.get(relative, {}):
                continue
            found.append((path, number, kind, spelled, original[number - 1].strip()))
    for table, is_type in ((EXEMPT_FUNCTIONS, False), (EXEMPT_TYPES, True)):
        for relative, names in table.items():
            for name in names:
                if (is_type, name) not in declared.get(relative, set()):
                    what = "型" if is_type else "関数"
                    stale.append(f"{relative} に {what} `{name}` が無い")
    return len(files), found, stale


def toolbox_problems(root):
    """道具の置き場が、道具の宣言を完全な形で持っているか。足りないものの説明の並び。"""
    toolbox = root / TOOLBOX
    if not toolbox.is_file():
        return [f"{toolbox} が無い"]
    text = code_of(toolbox.read_text(encoding="utf-8"))
    return [f"{toolbox} に `{name}` の宣言が無い" for name, pattern in TOOL_DECLARATIONS.items()
            if not pattern.search(text)]


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else "Sources")
    problems = toolbox_problems(root)
    if problems:
        print("attach-result: " + " / ".join(problems) + " — 案内する道具が無いまま緑にはしない", file=sys.stderr)
        return 1
    count, found, stale = findings(root)
    if count == 0:
        print(f"attach-result: {root} の下に Swift のファイルが 1 つも無い"
              " — 見るものが無いまま緑にはしない", file=sys.stderr)
        return 1
    if stale:
        print("attach-result: 許可が空振りしている (名前を変えたのに許可が残ると、別の所を黙って許す): "
              + " / ".join(stale), file=sys.stderr)
        return 1
    if not found:
        print(f"attach-result: {count} 個の Swift を見た。道具を通さない attach の呼び出し・参照は無い")
        return 0
    print(f"attach-result: 道具を通さない attach がある ({len(found)} 箇所)。足せなかった `false` を捨てると、"
          "外で呼ばれたとき足されていない入り口を黙って返す (#2740・#2794)", file=sys.stderr)
    for path, number, kind, spelled, line in found:
        if kind == "throwing":
            what = "投げる口の中で `attach(_:calledAs:returning:)` は使えない (外では notRunning を投げず、黙って返す)。`attached(_:calledAs:making:)` へ"
        elif kind == "reference":
            what = "`attach` を呼ばずに参照している (結果を捨てる呼び出しが見えない)。道具を通す"
        else:
            what = f"`attach({spelled})` を道具へ置き換える"
        print(f"  {path}:{number}: {what}: {line}", file=sys.stderr)
    print("次にすること: 確かめて足すまでを 1 回で行う道具を通す — 投げる口は "
          "`attached(_:calledAs:making:)`、面の上に作る口は `attachedOnSurface(_:calledAs:making:)`、"
          "投げない口は `attach(_:calledAs:returning:)` (どれも "
          f"{'Sources/' + TOOLBOX}。理由は #2794)。Inlet・Outlet でない別の型の `attach` なら、"
          "scripts/check-attach-result.py の `EXEMPT_TYPES` に (ファイル, 型) を理由つきで足す", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
