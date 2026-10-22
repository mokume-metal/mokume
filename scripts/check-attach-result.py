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
`attached(_:calledAs:making:)`・`attachedAfterSurface(_:)`・`attach(_:calledAs:returning:)`)。
足せなかった結果を捨てるのは、道具の中の 1 か所だけにする。**ここで、道具を通さない素の `attach(x)` を
数える。** 組み上げは要らない — 字句だけを読む (`scripts/check-runtime-math.py` と同じ形)。

## 見るもの

- 対象は `Sources/MokumeAudio`・`MokumeCamera`・`MokumeNetwork`・`MokumeGamepad` の Swift
  (走っている実行へ入り口を足す作る口の置き場)。`MokumeCore` は道具の置き場なので見ない
- 数えるのは `attach(` の呼び出しで、次のどれかを満たすもの。**呼び出しが `calledAs:` を持てば道具の形なので数えない**
  (`attach(x, calledAs: …, returning: …)`)。受け手が無い `attach(x)`、または受け手が `self`・`sketch`・`owner`
  (スケッチを指す名前) のもの。**数えないもの**: 宣言 (`func attach(`)・ほかの型の同名の口
  (`engine.attach(node)` の `AVAudioEngine` など。受け手がスケッチでない)・コメントと文字列の中
- **許す素の呼び出しは 1 つだけ**: `MokumeNetwork/Datagram.swift` の `attach(opened)` は `NWConnection` を
  繋ぐ同じ綴りの別物で、スケッチの `attach` ではない。**許すのは (ファイル, 引数の綴り) の対で、ファイルごとは許さない**
  (その中に新しい素の `attach(x)` が足されれば赤くなる)
- **道具の置き場 (`MokumeCore/Sketch/Sketch+Seams.swift`) が `attached` を定義していなければ落とす**
  (道具を動かしたのに、案内が無い道具を指したまま緑にならない)

字句の読みは `scripts/check-tool-language.py` の `blank_comments` を取り込んで使う
(`check-runtime-math.py` と同じ。写さない)。

**見るのは作業ツリーで、git の木ではない** (#2016)。害がうるさい側 (手元だけ赤) だけで、CI の
木は作業ツリーの部分集合なので、逆向き (手元で緑・CI で赤) にはならない。

使い方: python3 scripts/check-attach-result.py [Sources のルート (既定 Sources)]
"""

import importlib.util
import re
import sys
from pathlib import Path

TARGETS = ("MokumeAudio", "MokumeCamera", "MokumeNetwork", "MokumeGamepad")
# 道具の置き場 (Sources のルートからの相対)。ここが `attached` を定義していなければ案内が空になる
TOOLBOX = "MokumeCore/Sketch/Sketch+Seams.swift"
# 素の呼び出しのうち、スケッチの `attach` ではないもの: {Sources のルートからの相対: {引数の綴り}}
NOT_THE_SKETCHES = {"MokumeNetwork/Datagram.swift": {"opened"}}
# 受け手がこれなら、スケッチへ足している呼び出し
SKETCH_RECEIVERS = ("self", "sketch", "owner")

CALL = re.compile(r"(?<![\w])(?P<declaration>func\s+)?(?P<receiver>(?:[A-Za-z_]\w*\s*\.\s*)*)attach\s*\(")


def _blank_comments():
    """check-tool-language.py の字句の読みを取り込む (ファイル名にハイフンがあるので importlib)。"""
    path = Path(__file__).resolve().parent / "check-tool-language.py"
    spec = importlib.util.spec_from_file_location("check_tool_language", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.blank_comments


blank_comments = _blank_comments()


def arguments(text, start):
    """`(` の直後 `start` から、対応する `)` までの引数の綴り。閉じなければ None。"""
    depth = 1
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start:index]
    return None


def findings(root):
    """(見た Swift の数, [(パス, 行番号, 引数の綴り, 行)])。"""
    files = sorted(
        path for target in TARGETS if (root / target).is_dir()
        for path in (root / target).rglob("*.swift"))
    found = []
    for path in files:
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        original = text.splitlines()
        blanked = blank_comments(text, strings=True)
        for match in CALL.finditer(blanked):
            if match.group("declaration"):
                continue
            receiver = match.group("receiver").replace(" ", "").rstrip(".")
            # 受け手がスケッチでなければ、ほかの型の同名の口 (`engine.attach(node)`)
            if receiver and receiver.split(".")[-1] not in SKETCH_RECEIVERS:
                continue
            args = arguments(blanked, match.end())
            if args is None or "calledAs:" in args:
                continue
            spelled = " ".join(args.split())
            if spelled in NOT_THE_SKETCHES.get(relative, ()):
                continue
            number = blanked.count("\n", 0, match.start()) + 1
            found.append((path, number, spelled, original[number - 1].strip()))
    return len(files), found


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else "Sources")
    toolbox = root / TOOLBOX
    if not toolbox.is_file() or "func attached" not in toolbox.read_text(encoding="utf-8"):
        print(f"attach-result: {toolbox} が無いか、`attached` を定義していない"
              " — 案内する道具が無いまま緑にはしない", file=sys.stderr)
        return 1
    count, found = findings(root)
    if count == 0:
        print(f"attach-result: {root} の {' / '.join(TARGETS)} の下に Swift のファイルが 1 つも無い"
              " — 見るものが無いまま緑にはしない", file=sys.stderr)
        return 1
    if not found:
        print(f"attach-result: {count} 個の Swift を見た。道具を通さない素の attach の呼び出しは無い")
        return 0
    print(f"attach-result: 道具を通さない素の attach がある ({len(found)} 箇所)。足せなかった `false` を捨てると、"
          "外で呼ばれたとき足されていない入り口を黙って返す (#2740・#2794)", file=sys.stderr)
    for path, number, spelled, line in found:
        print(f"  {path}:{number}: `attach({spelled})` を道具へ置き換える: {line}", file=sys.stderr)
    print("次にすること: 確かめて足すまでを 1 回で行う道具を通す — 投げる口は "
          "`attached(_:calledAs:making:)`、面を確かめ済みの口は `attachedAfterSurface(_:)`、"
          "投げない口は `attach(_:calledAs:returning:)` (どれも "
          f"{'Sources/' + TOOLBOX}。理由は #2794)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
