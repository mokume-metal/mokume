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

## 1 本で長い検査 (`--slow <記録> [<秒>]`・#3194)

`make test` が、`swift test` が終わった回の最後に呼ぶ (緑でも赤でも)。1 本で N 秒 (既定 5) 以上かかった検査を、
長い順に `<秒>s  <classname>/<name>` で出す。検査が 1 本ずつ重くなっても誰も気付かないまま、
test 段が 3 週間で約 2 倍になった (#3190) — 上位 10 本で累計の 57% を占めていたのに、名指し
されたのは手の集計だけだった。秒は `<testcase time="…">` で、並行して走る検査では main actor
などの待ちも含む (壁時計の始まりから終わりまで)。

`$GITHUB_STEP_SUMMARY` があれば、同じ一覧を Markdown の表でそこへ追記する。PR の run を
開けば見えるようにするためで、workflow の側には何も足さない (`make` が環境変数を継ぐ)。

**黙って空を出さない。** 記録が無い・読めない・検査が 1 件も無い・どの検査も `time` を
持たない、はそれぞれ名乗る (要約にも書く)。`time` の綴りが変わった日に「長い検査は無い」と
読めてしまうと、見張りが黙って止まる。N 秒以上が無い回も、無いと言う。

**警告だけで、終了コードは常に 0** — 段の結末は変えない。赤にするか・予算を設けるかは、
名乗らせた後の実測で別に決める。
## 取り消した検査 (`--cancelled <事象の記録>`・#3348)

`make test` が、`swift test` が終わった回の最後に呼ぶ (緑でも赤でも)。`Test.cancel` で検査の
途中から取り消した検査を、名前・ケース・理由つきで名乗る。取り消しは xUnit の上では passed と
同じ `<testcase/>` に見え、端末の出力にも (1 ケースの取り消しは) 出ない。前提が崩れた回に
検査が何も確かめないまま緑になる — いま `Test.cancel` で取り消す検査は
`DocumentLoadingTests` と `APIListDownloadTests` の「5 回とも前提が成り立たなかった」の枝である。

**読む元は xUnit ではなく、`swift test --event-stream-output-path <置き場> --event-stream-version 0`
の事象の記録** (1 行 1 JSON)。プロセスが自分でファイルへ書くので端末のように行を落とさず、
丸ごとの取り消し (`testCancelled`) も 1 ケースの取り消し (`testCaseCancelled`) も持つ。

- **Swift 6.3.3 は、丸ごとの取り消しに `testCancelled` と、同じ testID の `testCaseCancelled`
  を両方出す** (6.4 は `testCancelled` だけ)。同じ testID に `testCancelled` が在れば、その
  testID の `testCaseCancelled` は丸ごとの取り消しの写しとして畳み、1 件に数える
- 理由は事象の `_comments`、ケースの名前は `_testCase.displayName`。どちらも版 0 の実験的な欄
  (`_` で始まる) で、版 6.3 以降の書式では消える。無い日は「理由が読めない」「ケースの名前が
  読めない」と名乗る (欄が消えても取り消しの件数は数えられる)。testID の欄が読めない事象は、
  どの testID とも照合できないので畳まず、1 件ずつ別に数える

`$GITHUB_STEP_SUMMARY` があれば、同じ一覧を Markdown でそこへ追記する (`--slow` と同じ作法)。

**黙って空を出さない。** 記録が無い・読めない・事象が 1 件も無い・`runStarted` が無い・取り消しが
0 件、はそれぞれ名乗る。0 件のときも「無い」と言い、読めない行や `runEnded` で閉じていない記録
(検査のプロセスが途中で消えた回) は添える。

**警告だけで、終了コードは常に 0** — 段の結末は変えない。取り消しを赤にするかは、名乗らせた後に
別に決める。

## GPU の打ち切り (`--gpu-dropped <test-log>`・#2275)

render.yml の検査の 4 job (`render`・`render-pr`・`scheduled-debug`・`scheduled-release`) が、検査と
記録の後に呼ぶ。GPU が仕事を打ち切っても、絵を読まない検査は緑のまま通る — 標準エラーに 1 行出る
だけで、記録にも job の結論にも残らない。#2251 の集計では、hang の行があった 25 run のうち赤に
なったのは絵を読む検査の 5 回だけだった。読むのは検査の出力 (`.build/test-log.txt`) で、
xunit の記録ではない: 打ち切りは検査の結末ではなく、土台が標準エラーへ言う 1 行だからである
(**端末の出力は行を落とす** (#1056) ので、行が無いことは打ち切りが無かったことの証明にならない。
名乗るのは見つかった分だけの下限である)。

**数えるのは本物の打ち切りの行だけ** — 土台 (`RenderDevice.swift` の `makeCommitOptions`) が
`droppedForTesting == nil` のときにだけ出す
`The GPU dropped the work it had queued, so this frame was never finished: <理由> — this notice will not be repeated`。
故意の打ち切りを起こす検査 (`dropsNextSubmissionForTesting` など) ではこの行は出ない。同じ「GPU が
仕事を打ち切った」を言う別の行 (`SketchRuntime` の `The GPU dropped the work behind frame N …`) は、
故意の打ち切りでも出るので数えない。この行は 1 プロセスで最初の打ち切りにしか出ない
(`this notice will not be repeated`) ので、件数は打ち切りの回数ではなく、打ち切りを受けた
プロセスの数に近い。

`$GITHUB_STEP_SUMMARY` があれば、理由ごとの件数を Markdown でそこへ追記する (`--slow` と同じ作法)。
**無かった回は要約に何も書かない** (4 job のほぼ全部の回が該当し、毎回「無い」と書くと本物が埋まる)。
**読めなかった回は名乗る** — 黙って空を出すと、見張りが止まっても誰も気付かない。

**警告だけで、終了コードは常に 0** — job の結論は変えない。赤にするかは、名乗りの件数が見えてから
別に決める (#2275 の決定)。故意と本物の見分けをログの文字列で行うと壊れやすく、赤にした途端に、
検査と無関係な GPU の揺れで merge queue が止まりうるためである。
"""

import json
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
GATE_CLOSED_OWN = "A wait for the GPU went past its limit earlier in this process"
# 別の回が残した gpu-slot の記録で止まった断り (RenderFailure.notResponding の record の枝・#2235)
GATE_CLOSED_RECORD = "A wait for the GPU went past its limit in another run under gpu-slot.py"
GATE_CLOSED = (GATE_CLOSED_OWN, GATE_CLOSED_RECORD)
# gpu-slot の記録が絡む断りの目印。記録は起こし直しでは消えず、人が消すまで次の回も止まる
GATE_RECORD = "gpu-slot.py"
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
# 1 本で長い検査の閾値の既定 (秒)。Makefile の TEST_SLOW_SECONDS が上書きする
SLOW_SECONDS = 5.0
# 一覧に載せる上限。手元の記録 (10-19) で 5 秒以上は 26 件だった
MAX_SLOW = 50
# 取り消し 1 行に並べるケース名の上限と、一覧に載せる上限
MAX_CASE_NAMES = 5
MAX_CANCELLED = 50


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
        return any(marker in f[2] for marker in GATE_CLOSED) and f[0] not in GATE_TEXT_SUITES

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
        if any(GATE_RECORD in f[2] for f in gate):
            out += [
                "**gpu-slot の期限切れの記録が残っている。** 専用機では、人が GPU の答えを確かめて記録を消すまで、"
                "次の job も前検査 (`runner-preflight.sh`) が `gpu-slot:` で止める。走らせ直すだけでは直らない (#2235)。",
                "",
            ]
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


def code_span(text):
    """表の 1 マスに置く code span。中の backtick より長い囲いにし、`|` は表を割らないよう逃がす。"""
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    tick = "`" * (longest + 1)
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return "%s%s%s%s%s" % (tick, pad, text.replace("|", "\\|"), pad, tick)


def slow(path, threshold=SLOW_SECONDS):
    """1 本で threshold 秒以上かかった検査を長い順に。(端末の文, 要約の Markdown) を返す。"""
    title = "1 本 %g 秒以上の検査" % threshold

    def cannot(reason):
        return (
            "%sを読めない: %s (%s)" % (title, reason, path),
            "### %s\n\n読めない: %s (`%s`)" % (title, reason, path),
        )

    try:
        if os.path.getsize(path) == 0:
            return cannot("記録が無い")
        cases = list(ET.parse(path).getroot().iter("testcase"))
    except OSError:
        return cannot("記録が無い")
    except ET.ParseError:
        return cannot("記録が壊れている — 途中で切れているか、閉じていない")
    if not cases:
        return cannot("記録に検査が 1 件も無い")
    timed = []
    for case in cases:
        try:
            timed.append((float(case.get("time")), case.get("classname", ""), case.get("name", "")))
        except (TypeError, ValueError):
            continue  # 飛ばした検査は time を持たない
    if not timed:
        return cannot("記録の検査 %d 件のどれも時間 (time) を持たない — 記録の書式が変わった可能性がある" % len(cases))

    total = sum(t for t, _, _ in timed)
    hits = sorted((c for c in timed if c[0] >= threshold), key=lambda c: -c[0])
    if not hits:
        line = "%sは無い (記録の検査 %d 件・合計 %.1f 秒)" % (title, len(cases), total)
        return line, "### %s\n\n無い (記録の検査 %d 件・合計 %.1f 秒)" % (title, len(cases), total)

    spent = sum(t for t, _, _ in hits)
    share = "合計 %.1f 秒 = 記録の検査時間 %.1f 秒の %d%%" % (spent, total, round(100 * spent / total) if total else 0)
    shown = hits[:MAX_SLOW]
    rest = len(hits) - len(shown)
    text = ["%s (%d 件・%s・長い順。警告だけで段の結末は変えない・#3194):" % (title, len(hits), share)]
    text += ["  %7.1fs  %s/%s" % c for c in shown]
    md = [
        "### %s (%d 件)" % (title, len(hits)),
        "",
        "%s。長い順。警告だけで、段の結末は変えない (#3194)。" % share,
        "",
        "| 秒 | 検査 |",
        "| ---: | --- |",
    ]
    md += ["| %.1f | %s / %s |" % (t, code_span(c), code_span(n)) for t, c, n in shown]
    if rest:
        text.append("  ほか %d 件は記録を読む" % rest)
        md += ["", "ほか %d 件は記録を読む" % rest]
    return "\n".join(text), "\n".join(md)


# testID が読めない取り消しの表示名。鍵に使わず、1 件ずつ別に数える
UNKEYED = "(testID が読めない)"


def read_cancellations(path):
    """事象の記録 (JSON Lines) から `Test.cancel` の取り消しを読む。

    (理由, 取り消し, 事象の数, 注) を返す。**理由が None でなければ読めていない**
    (取り消しは空)。取り消しは (testID, 範囲, 件数, 理由) の列で、testID が読めない事象は
    None を入れて 1 件ずつ別に数える (畳むと別々の取り消しが 1 件に潰れる)。理由が読めない
    ときの理由は None。`scripts/mutate.py` もここを共有する。
    """
    try:
        if os.path.getsize(path) == 0:
            return "記録が無い", [], 0, []
        with open(path, encoding="utf-8") as f:
            # **レコードの境界は LF だけ** (JSON Lines)。`splitlines()` は U+2028 / U+2029 / U+0085 でも
            # 割るが、JSON の文字列にはそれがそのまま入りうる — 割ると正常な記録が読めない行になり、
            # 取り消しを取りこぼす (#3499)。CRLF は読み込みの改行の読み替えで LF に揃い、最終行の
            # 空の断片と空行は下で読み飛ばす
            lines = f.read().split("\n")
    except OSError:
        return "記録が無い", [], 0, []
    except UnicodeDecodeError:
        return "記録が壊れている — 文字として読めない", [], 0, []

    events = []
    broken = 0
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            payload = record["payload"]
            if record["kind"] == "event" and isinstance(payload, dict) and isinstance(payload["kind"], str):
                events.append(payload)
        except (ValueError, KeyError, TypeError):
            broken += 1
    if not events:
        return "記録に事象が 1 件も無い" + ("" if not broken else " (読めない行 %d 行)" % broken), [], 0, []
    kinds = {e["kind"] for e in events}
    if "runStarted" not in kinds:
        return (
            "記録の事象 %d 件に runStarted が無い — 記録の書式が変わったか、`--event-stream-version 0` で書かれていない可能性がある"
            % len(events),
            [],
            len(events),
            [],
        )

    # testID ごとに、丸ごと (testCancelled) とケース (testCaseCancelled) を集める。
    # testID が読めない事象は、どの testID とも照合できないので畳まず 1 件ずつ数える
    whole = {}
    cases = {}
    unkeyed = []  # (丸ごとか, ケースの名前, 理由)
    for e in events:
        if e["kind"] not in ("testCancelled", "testCaseCancelled"):
            continue
        test_id = e.get("testID")
        comments = e.get("_comments")
        reason = " / ".join(str(c) for c in comments) if isinstance(comments, list) and comments else None
        test_case = e.get("_testCase")
        name = test_case.get("displayName") if isinstance(test_case, dict) else None
        name = name if isinstance(name, str) else None
        is_whole = e["kind"] == "testCancelled"
        if not isinstance(test_id, str) or not test_id:
            unkeyed.append((is_whole, name, reason))
        elif is_whole:
            if whole.get(test_id) is None:
                whole[test_id] = reason
        else:
            cases.setdefault(test_id, []).append((name, reason))

    # 同じ testID の testCaseCancelled は、丸ごとの取り消しの写し (Swift 6.3.3) として畳む。
    # 写しの側にだけ理由が載る版でも、理由は拾う
    for test_id in whole:
        for _, reason in cases.pop(test_id, []):
            if whole[test_id] is None:
                whole[test_id] = reason

    items = []  # (testID, 取り消しの範囲, 件数, 理由)
    for test_id, reason in whole.items():
        items.append((test_id, "丸ごと", 1, reason))
    for test_id, entries in cases.items():
        by_reason = {}
        for name, reason in entries:
            by_reason.setdefault(reason, []).append(name)
        for reason, names in by_reason.items():
            known = [n for n in names if n is not None]
            unknown = len(names) - len(known)
            shown = ", ".join(known[:MAX_CASE_NAMES])
            if len(known) > MAX_CASE_NAMES:
                shown += " ほか %d 件" % (len(known) - MAX_CASE_NAMES)
            if unknown:
                shown += ("; " if shown else "") + "名前が読めない %d 件" % unknown
            items.append((test_id, "ケース %s" % shown, len(names), reason))
    for is_whole, name, reason in unkeyed:
        scope = "丸ごと" if is_whole else "ケース %s" % (name if name is not None else "名前が読めない 1 件")
        items.append((None, scope, 1, reason))

    notes = []
    if unkeyed:
        notes.append("testID が読めない取り消しが %d 件ある — どれとも照合できないので畳まず 1 件ずつ数えた" % len(unkeyed))
    if broken:
        notes.append("読めない行が %d 行あった" % broken)
    if "runEnded" not in kinds:
        notes.append("記録が runEnded で閉じていない — 検査のプロセスが途中で消えた可能性がある")
    return None, items, len(events), notes


def cancelled(path):
    """`Test.cancel` で取り消した検査を事象の記録から。(端末の文, 要約の Markdown) を返す。"""
    title = "取り消した検査"
    reason, items, event_count, notes = read_cancellations(path)
    if reason is not None:
        return (
            "%sを読めない: %s (%s)" % (title, reason, path),
            "### %s\n\n読めない: %s (`%s`)" % (title, reason, path),
        )
    if not items:
        notes_text = "".join(" (%s)" % n for n in notes)
        line = "%sは無い (記録の事象 %d 件)%s" % (title, event_count, notes_text)
        return line, "### %s\n\n無い (記録の事象 %d 件)%s" % (title, event_count, notes_text)

    total = sum(n for _, _, n, _ in items)
    no_reason = sum(n for _, _, n, r in items if r is None)
    if no_reason:
        notes.append(
            "%d 件は理由の欄 (`_comments`) が無く読めない — `--event-stream-version 0` で書かれていない可能性がある" % no_reason
        )
    shown = items[:MAX_CANCELLED]
    rest = len(items) - len(shown)

    def why(reason):
        return " ".join(reason.split()) if reason is not None else "理由が読めない"

    head = "%s %d 件 (Test.cancel — xUnit の上では passed と区別できない。警告だけで段の結末は変えない・#3348):" % (title, total)
    text = [head]
    text += ["  %s — %s — %s" % (i if i is not None else UNKEYED, scope, why(r)) for i, scope, _, r in shown]
    md = [
        "### %s (%d 件)" % (title, total),
        "",
        "`Test.cancel` で取り消した検査。xUnit の上では passed と区別できない。警告だけで、段の結末は変えない (#3348)。",
        "",
        "| 検査 | 範囲 | 理由 |",
        "| --- | --- | --- |",
    ]
    md += [
        "| %s | %s | %s |"
        % (code_span(i if i is not None else UNKEYED), scope.replace("|", "\\|"), why(r).replace("|", "\\|"))
        for i, scope, _, r in shown
    ]
    if rest:
        text.append("  ほか %d 行は記録を読む" % rest)
        md += ["", "ほか %d 行は記録を読む" % rest]
    for n in notes:
        text.append("  注: " + n)
        md += ["", "注: " + n]
    return "\n".join(text), "\n".join(md)


# 土台が本物の打ち切りでだけ標準エラーへ出す 1 行 (RenderDevice.swift の makeCommitOptions)。
# 英語の文面を写しているので、本物と合っていることは test_vanished_test.py が Sources から確かめる。
# 行頭の `mokume: ` や、並走する出力の混ざりに依らないよう、行のどこにあっても拾う
GPU_DROPPED = re.compile(
    r"The GPU dropped the work it had queued, so this frame was never finished: (?P<reason>.*?)"
    r"(?: — this notice will not be repeated)?\s*$"
)
MAX_DROPPED_REASONS = 20


def gpu_dropped(path):
    """検査の出力から、本物の GPU の打ち切りを理由ごとに。(端末の文, 要約の Markdown or None) を返す。

    要約は、1 件以上あったときと、読めなかったときだけ書く (無かった回は黙る)。
    """
    title = "GPU の打ち切り"
    reasons = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = GPU_DROPPED.search(line)
                if m:
                    reason = " ".join(m.group("reason").split()) or "理由が読めない"
                    reasons[reason] = reasons.get(reason, 0) + 1
    except OSError:
        return (
            "%sを読めない: 検査の出力が無い (%s)" % (title, path),
            "### %s\n\n読めない: 検査の出力が無い (`%s`)" % (title, path),
        )
    total = sum(reasons.values())
    if not total:
        return "%sは見つからなかった (%s)" % (title, path), None

    ordered = sorted(reasons.items(), key=lambda kv: (-kv[1], kv[0]))
    shown = ordered[:MAX_DROPPED_REASONS]
    rest = len(ordered) - len(shown)
    head = "%s %d 件 (本物の打ち切りだけ。警告だけで job の結論は変えない・#2275):" % (title, total)
    text = [head] + ["  %d 件  %s" % (n, r) for r, n in shown]
    md = [
        "### %s (%d 件)" % (title, total),
        "",
        "検査の出力に、本物の GPU の打ち切り (`The GPU dropped the work it had queued`) があった。"
        "**絵を読まない検査は、打ち切りがあっても緑のまま通る**ので、job は success でも、"
        "同じ run の検査の結果は打ち切りの影響を受けていないとは言えない。"
        "警告だけで、job の結論は変えない (#2275)。",
        "",
        "この行は 1 プロセスで最初の打ち切りにしか出ない (`this notice will not be repeated`) ので、"
        "件数は打ち切りの回数ではなく、打ち切りを受けたプロセスの数に近い。"
        "端末の出力は行を落とす (#1056) ので、件数は下限である。",
        "",
        "| 件数 | 理由 |",
        "| ---: | --- |",
    ]
    md += ["| %d | %s |" % (n, code_span(r)) for r, n in shown]
    if rest:
        text.append("  ほか %d 種類の理由は検査の出力を読む" % rest)
        md += ["", "ほか %d 種類の理由は検査の出力 (`%s`) を読む" % (rest, path)]
    return "\n".join(text), "\n".join(md)


def append_summary(md):
    """`$GITHUB_STEP_SUMMARY` があれば Markdown を足す。書けなかったことは名乗る。"""
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    try:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(md + "\n\n")
    except OSError as e:
        print("job の要約へ書けなかった (%s): %s" % (summary, e))


def main(argv):
    if len(argv) == 3 and argv[1] == "--failures":
        print(failures(argv[2]))
        return 0
    if len(argv) in (3, 4) and argv[1] == "--slow":
        try:
            threshold = float(argv[3]) if len(argv) == 4 else SLOW_SECONDS
            if not threshold >= 0:
                raise ValueError
        except ValueError:
            print("1 本で長い検査の閾値は 0 以上の秒数で渡す: '%s'" % argv[3])
            return 0
        text, md = slow(argv[2], threshold)
        print(text)
        append_summary(md)
        return 0
    if len(argv) == 3 and argv[1] == "--cancelled":
        text, md = cancelled(argv[2])
        print(text)
        append_summary(md)
        return 0
    if len(argv) == 3 and argv[1] == "--gpu-dropped":
        text, md = gpu_dropped(argv[2])
        print(text)
        if md is not None:
            append_summary(md)
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
