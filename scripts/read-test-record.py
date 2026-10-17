#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""テストの記録 (xunit XML) から、名指しした検査の結末とスキップの数を読む (#1056)。

**なぜ端末の出力を読まないか。** swift-testing の端末出力は実行ごとに数十〜数百行を
落とす。全件が緑で `make` が 0 を返しているのに、走った検査の `✔ passed` や
`✔ Suite passed` や最終要約が記録に無い、という状態が起きる。落ちる集合は実行ごとに
別物で、管を外しても Metal の nslog を切っても止まらない (上流の挙動)。
かつての手元の実行の報告 (`render-status.sh`・#879 で畳んだ) はその出力の **1 行**を
grep して報告するか決めており、その行が落ちた実行では「GPU が無い機械の実行」という
嘘の理由で報告が止まった。

SwiftPM が `--xunit-output` で自分でファイルへ書く記録は、同じ実行で全件を持っていた。
判定はそちらから読む。

**XML を grep で読まない。** 見たいのは要素の入れ子 (`<testcase>` の子に `<skipped>` /
`<failure>` が居るか) で、行の並びに依らせると書式が変わった日に黙って通る側へ倒れる。

出すのは `<結末> <スキップの数>` の 1 行。結末は 4 つ:

    passed      その classname の検査が在り、落ちても飛ばされてもいない
    skipped     在るが、すべて飛ばされている (この世代の GPU が無い機械の実行)
    failed      在るが、落ちている
    absent      記録に無い

読めなければ `unreadable 0` を出す。**終了コードは常に 0** — 判定は呼ぶ側が行を読んで
決める。呼ぶのは `make gpu-ran` (専用機の描画ジョブで、台帳の検査が走ったかを見る・#878)
で、`unreadable` も赤として扱う。

## 記録全体の失敗の数 (`--failures <記録>`・#1526)

`make test` が、`swift test` が終わった回に呼ぶ (`scripts/test-vanished.sh`)。0 で
終わった回も呼ぶ (#1688)。検査のプロセスが要約を残さずに消えた回と、普通の赤・緑とを
分けるためで、出すのは 1 行:

    missing      記録が無い (空のファイルも含む — Makefile の `test -s` と同じ線)
    unreadable   在るが読めない (本物の helper を kill -9 した回は、宣言と根の開き
                 だけの 52 バイトが残った)。根が閉じていない記録もここに入る
    failures N   読めて、`<failure>` か `<error>` を持つ検査が N 件

終了コードは同じく常に 0 にする。判定は呼ぶ側が行を読んで決める。

## 落ちた検査の文面 (`--failure-messages <記録> [<絵の artifact>]`・#1773)

専用機の描画ジョブが落ちた回に、ジョブの要約 (`$GITHUB_STEP_SUMMARY`) へ書く Markdown を
出す。専用機の記録は次のジョブが消すので、赤を読んで直す材料を run の画面に残すためで
ある。ジョブのログは端末の出力なので、上のとおり行を落とす。

台帳 (`SceneLedgerTests`) の失敗が書き換え後の行を名乗っていれば、それを先頭に 1 つの
塊として集める。**集めた行は案であって、台帳へ写す前に絵を目で見る** (ADR-0019 決定 3)。
行の形は `Ledger.line` (`<名前> <sha256 の 16 進 64 桁>[ os=<版>]`) に合わせる。
絵の置き場として案内する artifact の名前は、3 つ目の引数で渡す。既定は `render` /
`render-pr` の `ledger-shots` で、定期の検査の起票 (`scripts/report-scheduled-render.sh`)
は `scheduled-debug-ledger-shots` を渡す (#2084)。

記録が無い・読めないときも、そう名乗る 1 行を出す。終了コードは常に 0 にする。

**GPU の待ちが期限を越えた回は、「環境で成り立たなかった」と先に名乗る** (#2662)。期限を
越えるとプロセスの関所 (`CommandQueueGate.process`) が閉じ、以後の GPU の検査はすべて
`gpuNotResponding` で落ちる。2026-10-13 09:20Z の専用機の定期の release では 2,108 件が
そうなり、先頭 80 件 (`MAX_MESSAGES`) が関所の巻き込みで埋まって、引き金の期限切れも release
固有の赤も載らなかった。関所の文面 (`GATE_CLOSED`) を持つ失敗は件数と 1 例に畳み、それ以外
(引き金と、本物の赤) を先に並べる。この回の GPU の検査は赤も緑も読めないので、走らせ直すまで
保証が欠けていることを言う。関所の文面そのものを検査する Suite (`GATE_TEXT_SUITES`) の赤は
畳まない。
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

LEDGER_CLASSNAME = "MokumeCoreTests.SceneLedgerTests"
LEDGER_LINE = re.compile(r"^\s+(\S+ [0-9a-f]{64}(?: os=\d+)?)\s*$")
# 要約は 1 step あたり 1 MiB まで。台帳が全行動いた回 (約 70 件) でも収まる数で切る
MAX_MESSAGES = 80
# 関所が閉じた後の失敗の文面の頭 (RenderFailure.notResponding)。英語の文面を写しているので、
# 本物と合っていることは scripts/tests/test_vanished_test.py が Sources から確かめる
GATE_CLOSED = "A wait for the GPU went past its limit earlier in this process"
# 最初の期限切れの要約 (CommandQueueGate.Closure.summary)。文面の括弧の中にある
GATE_FIRST = re.compile(r"\((the first was [^)]*)\)")
# 関所の文面そのものを検査する Suite。落ちると文面を失敗の文に載せるが、関所が閉じた巻き込み
# ではなく本物の赤なので畳まない (畳むと「環境で成り立たなかった」と誤って名乗る)。Tests/ で
# 関所の文面を扱う Suite がここに揃っていることは test_vanished_test.py が確かめる
GATE_TEXT_SUITES = frozenset(
    {
        "MokumeCoreTests.CommandQueueGateTests",
        "MokumeCoreTests.CommandQueueGateWordingTests",
        "MokumeCoreTests.StartupFailureTests",
    }
)


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


def failures(path):
    """記録全体で、落ちた (`<failure>` / `<error>` を持つ) 検査の数。"""
    try:
        if os.path.getsize(path) == 0:
            return "missing"
    except OSError:
        return "missing"
    try:
        cases = list(ET.parse(path).getroot().iter("testcase"))
    except (OSError, ET.ParseError):
        return "unreadable"
    failed = sum(
        1 for c in cases if c.find("failure") is not None or c.find("error") is not None
    )
    return "failures %d" % failed


def fenced(text):
    """文面を、中の backtick の並びより長い囲いで包む。"""
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    return "%stext\n%s\n%s" % (fence, text, fence)


def keep_attribute_newlines(raw):
    """属性値の中の生の改行とタブを、文字参照へ戻す。

    専用機 (macOS 27) の SwiftPM は、文面の改行を `&#10;` ではなく生の改行のまま
    `message="…"` へ書く。XML の仕様は属性値の生の改行を空白へ正規化するので、そのまま
    読むと文面が 1 行に潰れ、台帳の行も拾えない (#1773 の赤の run で見つけた)。手元の
    macOS 26 は `&#10;` で書くので、手元の記録では起きない。属性値は `"` を `&quot;` に
    して書かれるので、`"…"` の範囲がそのまま 1 つの値になる。
    """
    def escape(m):
        value = m.group(1).replace("\r", "&#13;").replace("\n", "&#10;").replace("\t", "&#9;")
        return '="%s"' % value

    return re.sub(r'="([^"]*)"', escape, raw)


def failure_messages(path, shots_artifact="ledger-shots"):
    """落ちた検査の名前と文面を Markdown で。台帳の書き換え後の行は先頭に集める。

    shots_artifact は台帳の絵を上げた artifact の名前。案内の文面に入る。
    """
    try:
        if os.path.getsize(path) == 0:
            return "記録が無い (`%s`)" % path
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except (OSError, UnicodeDecodeError):
        return "記録が無い (`%s`)" % path
    try:
        root = ET.fromstring(keep_attribute_newlines(raw).encode("utf-8"))
        cases = list(root.iter("testcase"))
    except ET.ParseError:
        return "記録を読めなかった (`%s`)" % path

    found = []
    for case in cases:
        for tag in ("failure", "error"):
            for node in case.findall(tag):
                # swift-testing は文面を message 属性にだけ書く (子の本文は持たない)
                found.append((case.get("classname", ""), case.get("name", ""), node.get("message") or ""))
    if not found:
        return "記録に落ちた検査は無い"

    ledger_lines = []
    for classname, _, text in found:
        if classname != LEDGER_CLASSNAME:
            continue
        for line in text.splitlines():
            m = LEDGER_LINE.match(line)
            if m:
                ledger_lines.append(m.group(1))

    def swept(f):
        return GATE_CLOSED in f[2] and f[0] not in GATE_TEXT_SUITES

    gate = [f for f in found if swept(f)]
    rest = [f for f in found if not swept(f)]

    out = ["### 落ちた検査 (%d 件)" % len(found), ""]
    if gate:
        first = GATE_FIRST.search(gate[0][2])
        out += [
            "**環境で成り立たなかった回である。** 落ちた %d 件のうち %d 件は、先に GPU の待ちが期限を"
            "越えてプロセスの関所が閉じた後の `gpuNotResponding` で、その後の GPU の検査は描かずに"
            "断られている。**この回の GPU の検査は赤も緑も読めず、この木の保証は、次に走らせ直すまで"
            "(定期なら次の周期、merge queue なら組み直し) 欠けている。**"
            % (len(found), len(gate)),
            "",
        ]
        if first:
            out += ["最初の期限切れ: %s。" % first.group(1), ""]
        out += [
            "関所の分を除いた %d 件 (引き金になった期限切れと、それ以外の赤) を先に並べ、関所の分は 1 例だけ載せる。"
            % len(rest),
            "",
        ]
    if ledger_lines:
        out += [
            "#### 台帳の書き換え後の行 (案)",
            "",
            "**写す前に絵を目で見る** (ADR-0019 決定 3)。絵は artifact の `%s` にある。" % shots_artifact,
            "",
            fenced("\n".join(ledger_lines)),
            "",
        ]
    for classname, name, text in rest[:MAX_MESSAGES]:
        out += ["#### `%s` / `%s`" % (classname, name), "", fenced(text), ""]
    if len(rest) > MAX_MESSAGES:
        out += ["ほか %d 件は artifact の記録を読む" % (len(rest) - MAX_MESSAGES), ""]
    if gate:
        classname, name, text = gate[0]
        out += [
            "#### 関所が閉じた後の失敗 (%d 件のうち 1 例): `%s` / `%s`" % (len(gate), classname, name),
            "",
            fenced(text),
        ]
    return "\n".join(out).rstrip()


def main(argv):
    if len(argv) == 3 and argv[1] == "--failures":
        print(failures(argv[2]))
        return 0
    if len(argv) in (3, 4) and argv[1] == "--failure-messages":
        print(failure_messages(*argv[2:]))
        return 0
    if len(argv) != 3:
        print("unreadable 0")
        return 0
    print("%s %d" % read(argv[1], argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
