#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""テストの記録 (xunit XML) から、名指しした検査の結末とスキップの数を読む (#1056)。

**なぜ端末の出力を読まないか。** swift-testing の端末出力は実行ごとに数十〜数百行を
落とす。全件が緑で `make` が 0 を返しているのに、走った検査の `✔ passed` や
`✔ Suite passed` や最終要約が記録に無い、という状態が起きる。落ちる集合は実行ごとに
別物で、管を外しても Metal の nslog を切っても止まらない (上流の挙動)。
`render-status.sh` はその出力の **1 行**を grep して `local-render` を報告するか決めて
おり、その行が落ちた実行では「GPU が無い機械の実行」という嘘の理由で報告が止まった。

SwiftPM が `--xunit-output` で自分でファイルへ書く記録は、同じ実行で全件を持っていた。
判定はそちらから読む。

**XML を grep で読まない。** 見たいのは要素の入れ子 (`<testcase>` の子に `<skipped>` /
`<failure>` が居るか) で、行の並びに依らせると書式が変わった日に黙って通る側へ倒れる。

出すのは `<結末> <スキップの数>` の 1 行。結末は 4 つ:

    passed      その classname の検査が在り、落ちても飛ばされてもいない
    skipped     在るが、すべて飛ばされている (この世代の GPU が無い機械の実行)
    failed      在るが、落ちている
    absent      記録に無い

読めなければ `unreadable 0` を出す。**終了コードは常に 0** — 呼ぶ側
(`render-status.sh`) は「報告しない理由を述べて 0 で終える」約束を持っており、
ここで落ちるとその約束を破ることになる。
"""

import sys
import xml.etree.ElementTree as ET


def verdict(cases, classname):
    """名指しした classname の検査が、記録の中でどうなっているか。"""
    mine = [c for c in cases if c.get("classname") == classname]
    if not mine:
        return "absent"
    if any(c.find("failure") is not None or c.find("error") is not None for c in mine):
        return "failed"
    if all(c.find("skipped") is not None for c in mine):
        return "skipped"
    return "passed"


def read(path, classname):
    try:
        cases = list(ET.parse(path).getroot().iter("testcase"))
    except (OSError, ET.ParseError):
        return "unreadable", 0
    skipped = sum(1 for c in cases if c.find("skipped") is not None)
    return verdict(cases, classname), skipped


def main(argv):
    if len(argv) != 3:
        print("unreadable 0")
        return 0
    print("%s %d" % read(argv[1], argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
