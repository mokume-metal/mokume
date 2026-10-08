#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""GPU の検査を、機械全体で共有する枠を 1 つ取ってから走らせる (#1898)。窓つきの計測は、
枠を全部取ってから走らせる (#2052・下の「## 窓つきの計測」)。

    python3 scripts/gpu-slot.py -- swift test --skip-build …
    python3 scripts/gpu-slot.py --exclusive -- <計測のコマンド…>

**同じ機械で GPU の検査が同時に走るのは、枠の数 (既定 3) までにする。** 複数のセッション
(並行する実装レーン) が `make test` を同時に回すと、GPU の資源切れ (`Cannot create a command
queue`・`kIOGPUCommandBufferCallbackErrorOutOfMemory`) で、変更と関係の無い suite が数百件
単位で赤になった (#1898 の表。5〜7 本が重なった回)。2〜3 本なら全体の段は 1 回で通った。
並べる数を束ねる側の判断で抑えるだけでは、レーンからも別のセッションからも見えず、守られる
保証が無い。そこで、`swift test` を走らせる所で縛る。

## 枠

- 置き場は `$MOKUME_GPU_SLOT_DIR` (既定 `~/Library/Caches/mokume/gpu-slots`)。`TMPDIR` は
  セッションや道具によって差し替えられうるので使わない — 置き場が割れると枠も割れる
- 枠は `slot-0.lock` から数えた N 個のファイルで、`fcntl.flock` の排他のロックを 1 つ取る。
  数は `$MOKUME_GPU_SLOTS` (既定 3・1 以上の整数)
- **枠はこのプロセスが終われば返る。** 落ちても殺されても OS が外すので、後片付けは要らない。
  ロックは子へ継がせない (Python の既定)。子が孫を残しても、枠を握り続けることはない
- 取れたら、ファイルへ持ち主 (PID・作業ツリー・始めた時刻) を書く。待つ側がそれを名乗る

## 待つ

空きが無ければ、数秒おきに取り直す。1 分おきに、何本がどこで走っているかを名乗る。
**待つ側が期限を持つ** (AGENTS.md「場面別の入口」の「待ちを含む検査を書く」)。
`$MOKUME_GPU_SLOT_WAIT` 秒 (既定 5400 = 90 分) を越えたら、持ち主を名乗って 75 で抜ける。
全体の test 段は 6〜8 分 (並列の幅を縛った後・下の「## 並列の幅」) なので、枠 3 に 10 本並んでも 30 分ほどで回ってくる。90 分を越えて
待つのは、持ち主が固まっているときである。

## 枠を取れない環境

置き場を作れない・ロックできないときは、**枠を取らずに子を走らせ、そうしたことを 1 行で
名乗る**。黙って素通りはしない。検査の段を止める側には倒さない — 枠は検査の保証ではなく、
混雑の抑えだからである。

## 窓つきの計測

**窓つきの計測と GPU の検査は、同じ機械で同時に走らせない** (#2052・メンテナの判断 2026-10-04)。
窓つきの計測とは、mokume のスケッチを窓つきで動かして性能や挙動を測る実行である。#2052 では、
枠の外で窓つきの計測 (窓 最大 8 枚・3840×2160・録画つき) が走っている間に、枠の内側の検査が GPU を
詰まらせ、手元機がカーネルパニックで落ちた。計測の負荷だけでは止まらなかった (#2052 の再現の
コメント) が、重なった場合については何も言えない。だから重ねない。

- `--exclusive` は、まず順番待ちの印 (置き場の `exclusive.lock`) を取る。次に枠を全部
  (`$MOKUME_GPU_SLOTS` 個) 取ってから、子を走らせる。検査が 1 本でも枠を握っていれば、空くまで待つ
- **印が握られている間は、普段の実行は空いた枠があっても新しく取らない。** 計測が待っている間に
  後から来た検査が枠を取ると、検査が途切れない限り、計測に順番が回ってこない。印を知らない古い版の
  gpu-slot (他の作業ツリー) も、枠が全部埋まっているので待つ。計測どうしは印で 1 本ずつになる
- 待ちの期限 (`$MOKUME_GPU_SLOT_WAIT`)・名乗り・起動元の記録は普段と同じである。待つ側は相手を
  名乗る (計測なら、印に書いたコマンドの先頭も)。記録の `take` には `"mode": "exclusive"` と、
  取った枠の一覧が載る
- 子には `MOKUME_GPU_SLOT_EXCLUSIVE` (包みの pid) を渡す。自分で包み直すスクリプトは、これを見て
  包み直さない。内側でもう一度 `--exclusive` を通しても、待たずにそのまま走らせる。自分の親が握る
  枠を待ち続けないためである
- **ビルドは包む前に済ませる。** ビルドの間も枠を握ると、検査を待たせるだけになる

このリポジトリでは、`scripts/measure-frame-rate.sh` と `scripts/check-observation-roundtrip.sh` が、
自分で `--exclusive` の内側へ入り直す。

**外から計測するとき** (probes など、このリポジトリの外の道具で mokume のスケッチを窓つきで測る
とき) は、同じ機械にある mokume の作業ツリーのこのスクリプトで、計測のコマンドを包む。枠の置き場は
既定のまま (`MOKUME_GPU_SLOT_DIR` を変えない) にする。変えると枠が割れて、検査と重なる:

    swift build -c release        # ビルドは包む前に
    python3 <mokume の作業ツリー>/scripts/gpu-slot.py --exclusive -- <計測のコマンド…>

**包まないもの:** 普段のスケッチの実行 (`mokume watch`・作品の起動)。作り手の実行を、検査の都合で
待たせない。

## 範囲の外

**素の `swift test` (全検査も `--filter …` も) は、この枠にも下の並列の幅にも届かない。範囲の
外と決めた (#2004)。** 縛りは、gpu-slot を通った実行にだけ掛かる。

素の実行が縛られていないことで起きた事故は、記録に無い。#1999 の 2 件のうち、カーネルパニックは
枠の内側の `make test-release` で起き、幅が無く 1 プロセスに発行口が並んだためで、下の並列の幅で
塞いだ。素の `--filter … --repeat-until` で WindowServer が止まったもう 1 件は、根が同じ suite の
中で `spin` が重なったことにあり、幅を掛けても防げなかった。そちらは suite の側で直した
(`.serialized` と、回転を残して返らない `settle()`)。残るのは、素の全検査では同時の発行口が
また上限なく並ぶ (debug で最大 248 本) という穴と、幅が無いことで #2007 の打ち切り (幅 4 以上で出る。
赤になるだけで、WindowServer は止めない) も起きうることで、事故が出てから足す (ADR-0008)。

**絞った実行は、gpu-slot を前置して打つ** (枠も幅も掛かる):

    python3 scripts/gpu-slot.py -- swift test --filter …

`make test` に絞り込みの口は無い。ビルドの指定が `make` と違えば作り直しが起きうる (Makefile の
`SYMBOL_GRAPH_FLAGS` の節)。

**枠の外のまま残す実行が 1 つある。** ShadowTests の負荷の手順は、重なりを作って遅れを炙り出す
検出器なので、わざと 6 本を同時に走らせる。gpu-slot を前置すると 3 本ずつに下がり、検出力だけが
落ちる。この規則の例外の置き場は、その手順の上である。

**縛りを足すのは、次のどちらかが起きたとき**: 素の実行で WindowServer が止まる・パニックが起きる
/ 下の並列の幅の口が効いていないと分かる。足すなら、縛る単位は `RenderDevice(` の呼び出し
(Tests に 400 余り) ではなく、suite の `TestScoping` の trait である。`RenderDevice.init` は
同期で `@MainActor` なので、中で待つと、検査が全部載っている main actor ごと止まる。GPU の suite
には `.enabled(if: RenderDevice.isAvailable, …)` が付いていて、`GPUGateTests` がその付け忘れを
見ているので、trait はそこへ並べる。

## 並列の幅

**枠が縛るのはプロセスの数で、1 プロセスの中で同時に進む検査の数は縛らない。** Swift Testing は
GPU を待って止まった非同期の検査を上限なく並べ、それぞれが自分の `RenderDevice` (コマンドの
発行口 1 本) を持つ。debug の全検査の 1 プロセスで、同時に生きる発行口は最大 248 本あった。
GPU は画面の描画 (WindowServer) と共有なので、全検査が重なって GPU が詰まると WindowServer が
ドライバの中で待たされ、watchdog が手元の機械ごと落とす (#1999。カーネルパニックまで行った)。

そこで、子へ `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` (Swift Testing の並列の幅) を
渡す。**既定は 1 である。** 最初は 16 にしていた (#1999。同時の発行口は 12 本に収まり、全体の所要は
1 割ほど延びた = 366 → 401 秒)。**呼ぶ側が環境に値を持っていれば、そちらを使う** (切り分けで幅を
変えて走らせるための口)。空の値は持っていないものとして扱う。

**1 にした理由 (#2007)。** 専用機で `EffectArgumentTests` だけを回すと、幅 4・16・100000 では
30 回中 7〜15 回で、GPU の仕事が `kIOGPUCommandBufferCallbackErrorPageFault` か `ErrorHang` で
打ち切られた。幅 1 では 30 回で 0 だった (2・3 は測っていない)。全検査でも、#2008 以降の専用機の
7 本中 6 本で出て、幅 1 では 2 回で 0 だった。`MTL4CommandQueue` (= `RenderDevice`) を解放しない・
遅らせる・使い回す・解放の後に 200ms 待つ、のどれでも消えたので、引き金はキューの解放の周りにある。
検査は main actor で直列に走る (`Package.swift` の既定の隔離) ので、幅 1 でも全体の所要は変わらない
(専用機の全検査で、幅 16 が 287〜288 秒、幅 1 が 285〜286 秒)。

**これは起きる条件を直さない、症状を避ける対処である。**
- **幅 1 でなぜ出ないかは、分かっていない。** 幅 1 でもケースの境目では「解放 → すぐ次の仕事」が起きる。
  ケースが同時に起動することが、解放の周りに別の仕事を重ねるのかもしれない。だとすれば、幅の外
  (`RenderDevice` を作っては捨てる経路) でも成り立ちうる。製品の経路で起きるかは確かめていない
- 標本は小さい。30 回の 0 は、95% で上限が約 10% にしか絞れない。キューを解放しない条件でも 1〜2/30 は
  残ったので、別の根があるかもしれない
- **幅 1 では塞げなかった経路がある**: GPU が応答しなくなった後、`RenderDevice.waitLimitSeconds` で待ちを
  打ち切って土台を畳み、次の検査が新しいキューを作り続けて、止まったキューが溜まる (#2052)。これは
  幅ではなく `RenderDevice` の側で塞いだ。待ちが一度期限を越えたプロセスでは、新しいキューを作らない
  (`Sources/MokumeCore/Rendering/CommandQueueGate.swift`)
- **測っていないのは**、手元機 (M3 Max) の所要と、幅 1 での同時の発行口の数 (検査が 1 本ずつなので
  1 本前後のはず) である

**口の名前に EXPERIMENTAL が付いている。** toolchain の更新で名前が変われば、Swift Testing は
知らない変数を読まないので、縛りは黙って外れる。幅の値と名前はここ 1 箇所にだけ置く。外れたかは、
専用機の全検査で `The GPU dropped the work` (`ErrorPageFault` / `ErrorHang`) が戻ること (幅 16 のときの
症状・#2007)、全検査の同時の発行口が数十本を越えて戻ること (#1999 の計り方)、または同じ機械の全検査の
重なりで WindowServer が止まることで分かる。そのときは、toolchain の `Testing` の文字列から今の名前を
引く。

## 起動元の記録

**枠を取った・返した・期限で抜けたときに、起動元を 1 行の JSON で追記する** (#2059)。置き場は
`$MOKUME_GPU_SLOT_LOG` (既定 `~/Library/Logs/mokume/gpu-slot.jsonl`)。枠のロックは次の持ち主に
上書きされるうえ、`pid / cwd / 時刻` しか持たない。#2052 のパニックでは、GPU を塞いだ全検査を
誰が起動したかを割り出すのに 1 時間かかった。正体は、エージェントのコマンドの引用符なしの heredoc
の中のバッククォートが、`make test-release` として実行されたものだった。記録には次を残す:

- `event` (`take` / `release` / `timeout`)・時刻・枠・自分の pid・cwd・子のコマンド・終了コード・所要
- `lineage`: 親プロセスを launchd の手前まで辿った各段の pid / ppid / 起動時刻 / コマンドラインの先頭。
  枠を待つ前に取る。#2052 の形なら、ここに `zsh -c … python3 - <<EOF …` の先頭が載る。ただし
  コマンドが長ければ、実行されてしまった箇所は切った先にありうる (各段 4000 字まで)
- `agent`: 環境にあるエージェントの出所 (`CLAUDE_CODE_SESSION_ID`・`MOKUME_AGENT_NAME` など)

**書けなくても検査は止めない** (1 行名乗るだけ)。行ごとにディスクまで落とす (パニックの直前の行が
いちばん欲しい)。大きさが上限 (4 MB) を越えたら、同じファイルの中で新しい半分だけを残す。
キャッシュの置き場と分けるのは、消してよい場所に調査の記録を置かないためである。

**手元機が落ちた・画面が固まったときの読み方:**

1. `/Library/Logs/DiagnosticReports/` の `panic-full-*.panic` と `WindowServer_*.spin` を開く。
   `.spin` の `swiftpm-testing-helper` のうち、GPU のドライバの中で止まったスレッドを持つものを探す。
   起動時刻は、`.spin` の先頭の時刻から `Time Since Fork` を引けば出る
2. その時刻の前後の `take` を、この記録から引く。cwd (どの worktree か) で絞る
3. `lineage` のコマンドラインと `agent` から、起動したセッションを特定する。Claude のセッションの操作
   記録は `find ~/.claude/projects -name '<CLAUDE_CODE_SESSION_ID>.jsonl'` で引ける (置き場の名前は
   セッションを始めたときの cwd から作られ、gpu-slot の cwd とずれうる)。その時刻の Bash の
   tool_use を読めば、何を打って起動したかが分かる

**この記録に載らないもの:** 枠を通らない実行 (素の `swift test`・ShadowTests の負荷の手順・
`make reference-shots`・包まずに起こした窓つきのスケッチ・`mokume watch`)。GPU を使っていたのに
ここに無ければ、それは枠の外の実行である (上の「範囲の外」・#2052)。窓つきの計測は、包んでいれば
`"mode": "exclusive"` の行で載る (上の「## 窓つきの計測」)。

子の終了コードは、そのまま返す。SIGINT / SIGTERM は子へ渡す。取り直しの間隔
(`$MOKUME_GPU_SLOT_POLL` 秒) と名乗る間隔 (`$MOKUME_GPU_SLOT_REPORT` 秒) は、検査が短く回す
ための口である。検査は scripts/tests/gpu_slot_test.py。
"""

import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_SLOTS = 3
DEFAULT_WAIT_SECONDS = 5400
EXIT_TIMED_OUT = 75
EXIT_USAGE = 2

# 窓つきの計測 (上の「## 窓つきの計測」)。順番待ちの印のファイル名と、子へ渡す「内側で走っている」の印
GATE_NAME = "exclusive.lock"
EXCLUSIVE_VARIABLE = "MOKUME_GPU_SLOT_EXCLUSIVE"
# 印に書く計測のコマンドの長さ。待つ側が名乗るためのもので、全文は起動元の記録にある
GATE_COMMAND_CHARACTERS = 200

# 起動元の記録 (上の「## 起動元の記録」)
LOG_LIMIT_BYTES = 4_000_000
# Claude のシェルは先頭に snapshot の source (この機械で約 280 字) を持つので、本題のコマンドまで
# 届く長さにする。Claude のアプリ本体は名前が分かれば足りるので短く切る (Homebrew の Python も
# Python.app の中にあるので、.app で一律には切らない — 切ると python3 - <<EOF の本文が落ちる)
LINEAGE_COMMAND_CHARACTERS = 4000
LINEAGE_APP_CHARACTERS = 200
# 起動元を名乗る環境変数。値が無いものは記録に載せない。エージェントの見分け方は
# scripts/comment.sh の判定と揃える
AGENT_VARIABLES = (
    "CLAUDECODE",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT",
    "CODEX_SANDBOX",
    "CODEX_HOME",
    "CODEX_THREAD_ID",
    "MOKUME_AGENT_NAME",
    "MOKUME_UNATTENDED",
)

# 並列の幅の口と既定 (上の「## 並列の幅」)
PARALLELIZATION_WIDTH_VARIABLE = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
DEFAULT_PARALLELIZATION_WIDTH = "1"


def _say(message):
    print(f"gpu-slot: {message}", file=sys.stderr, flush=True)


def _number(name, default, *, integer):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw) if integer else float(raw)
    except ValueError:
        value = None
    if value is None or value <= 0 or (integer and value < 1):
        _say(f"{name}={raw!r} は使えない (正の{'整数' if integer else '数'}を渡す)")
        sys.exit(EXIT_USAGE)
    return value


def _span(seconds):
    """待った長さ・期限を名乗る形にする。1 分に満たなければ秒で言う。"""
    return f"{int(seconds // 60)} 分" if seconds >= 60 else f"{int(seconds)} 秒"


def _slot_dir():
    configured = os.environ.get("MOKUME_GPU_SLOT_DIR")
    if configured:
        return Path(configured)
    return Path.home() / "Library" / "Caches" / "mokume" / "gpu-slots"


def _log_path():
    configured = os.environ.get("MOKUME_GPU_SLOT_LOG")
    if configured:
        return Path(configured)
    return Path.home() / "Library" / "Logs" / "mokume" / "gpu-slot.jsonl"


def _lineage():
    """自分から launchd の手前まで、親プロセスを辿る。各段の pid・ppid・起動時刻・コマンドラインを返す。

    起動時刻 (lstart) はロケールで形が変わる (ja_JP では日付が 4 語になる) ので、C ロケールで読む。
    コマンドラインは UTF-8 でないバイトを含みうるので、置き換えて読む。
    """
    chain = []
    pid = os.getpid()
    seen = set()
    environment = {**os.environ, "LC_ALL": "C"}
    while pid > 1 and pid not in seen and len(chain) < 32:
        seen.add(pid)
        out = subprocess.run(
            ["ps", "-o", "ppid=,lstart=,command=", "-p", str(pid)],
            capture_output=True, timeout=5, env=environment,
        ).stdout.decode("utf-8", errors="replace").strip()
        # C ロケールの lstart は "Sun Oct  4 13:29:27 2026" の 5 語
        fields = out.split(None, 6)
        if len(fields) < 6 or not fields[0].isdigit():
            break
        parent = int(fields[0])
        command = fields[6] if len(fields) > 6 else ""
        executable = command.split(" -", 1)[0].lower()
        limit = LINEAGE_APP_CHARACTERS if "/claude.app/" in executable else LINEAGE_COMMAND_CHARACTERS
        chain.append({"pid": pid, "ppid": parent, "started": " ".join(fields[1:6]), "command": command[:limit]})
        pid = parent
    return chain


def _origin():
    """起動元: 親プロセスの連鎖とエージェントの出所。枠を待つ前に取る — 待つ間に起動したシェルが
    終わると、連鎖は launchd に付け替えられて途切れる。"""
    try:
        lineage = _lineage()
    except Exception as error:  # 記録のための読み取りで検査を止めない
        lineage = [{"error": repr(error)}]
    agent = {name: os.environ[name] for name in AGENT_VARIABLES if os.environ.get(name)}
    return {"lineage": lineage, "agent": agent}


def _record(event, **fields):
    """起動元の記録へ 1 行追記する。**何が起きても例外を外へ出さない** — 記録のために検査を止めたり、
    子の終了コードや期限切れの 75 を置き換えたりしない。"""
    path = _log_path()
    try:
        try:
            cwd = os.getcwd()
        except OSError as error:
            cwd = f"<読めない: {error}>"
        entry = {"event": event, "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "pid": os.getpid(), "cwd": cwd, **fields}
        line = (json.dumps(entry, ensure_ascii=False) + "\n").encode("utf-8", errors="replace")
        path.parent.mkdir(parents=True, exist_ok=True)
        # 置き換え (os.replace) で切り詰めると、ロックを待っていた他のプロセスが名前の外れた古い
        # ファイルへ書き、その行が消える。同じファイルの中で切り詰める
        with open(path, "ab+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            handle.write(line)
            handle.flush()
            if handle.tell() > LOG_LIMIT_BYTES:
                handle.seek(0)
                data = handle.read()
                keep = data[len(data) - LOG_LIMIT_BYTES // 2:]
                keep = keep[keep.find(b"\n") + 1:]
                handle.truncate(0)
                handle.write(keep)
                handle.flush()
            # パニックの直前の行がいちばん欲しいので、ディスクまで落とす (macOS の fsync は
            # ドライブのキャッシュに留まりうる)
            try:
                fcntl.fcntl(handle.fileno(), fcntl.F_FULLFSYNC)
            except (AttributeError, OSError):
                os.fsync(handle.fileno())
    except Exception as error:
        _say(f"起動元の記録 {path} に書けなかった ({error!r})。検査はそのまま走らせる")


def _try_take(path, command=None):
    """枠のファイルを 1 つ排他で取る。取れたら開いたままのファイルを、取れなければ None を返す。

    `command` を渡すと 4 つ目の欄に書く (順番待ちの印だけが書く)。枠のファイルは 3 欄のままにする —
    印を知らない古い版の gpu-slot.py (他の作業ツリー) も、枠の持ち主を読めるように。"""
    handle = open(path, "a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    handle.seek(0)
    handle.truncate()
    note = ""
    if command is not None:
        # UTF-8 でない引数 (surrogateescape で来る) は書けないので置き換える。欄と行は崩さない
        text = " ".join(command).encode("utf-8", errors="replace").decode("utf-8")
        note = "\t" + text.replace("\t", " ").replace("\n", " ")[:GATE_COMMAND_CHARACTERS]
    handle.write(f"{os.getpid()}\t{os.getcwd()}\t{int(time.time())}{note}\n")
    handle.flush()
    return handle


def _gate_holder(gate):
    """順番待ちの印を握っている計測を、名乗るための行にして返す。誰も握っていなければ None。"""
    try:
        with open(gate, "r") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                record = handle.read().strip().split("\t", 3)
            else:
                return None  # 共有で取れた = 誰も持っていない
    except OSError:
        return None  # まだ誰も計測していない (印のファイルが無い)
    if len(record) == 4 and record[2].isdigit():
        minutes = int((time.time() - int(record[2])) // 60)
        return f"  - 窓つきの計測 ({GATE_NAME}): pid {record[0]} · {record[1]} · {minutes} 分前から · {record[3]}"
    return f"  - 窓つきの計測 ({GATE_NAME}): 持ち主を読めない"


def _holders(paths):
    """いま握られている枠の持ち主を、名乗るための行にして返す。"""
    now = time.time()
    lines = []
    for path in paths:
        try:
            with open(path, "r") as handle:
                try:
                    fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    record = handle.read().strip().split("\t")
                else:
                    continue  # 共有で取れた = 誰も持っていない
        except OSError:
            continue
        if len(record) == 3 and record[2].isdigit():
            minutes = int((now - int(record[2])) // 60)
            lines.append(f"  - {path.name}: pid {record[0]} · {record[1]} · {minutes} 分前から")
        else:
            lines.append(f"  - {path.name}: 持ち主を読めない")
    return lines


def _give_up(what, subject, wait_seconds, started, now, busy, origin):
    """期限を越えた。相手を名乗り、記録に残して 75 で抜ける。"""
    _say(
        f"{what}が {_span(wait_seconds)}空かなかったので、{subject}を走らせずに抜ける。"
        " 持ち主が固まっていないか確かめる (MOKUME_GPU_SLOT_WAIT で期限を変えられる):"
    )
    for line in busy:
        print(line, file=sys.stderr, flush=True)
    print(f"  (持ち主の起動元は {_log_path()} の take の行にある)", file=sys.stderr, flush=True)
    _record("timeout", waited_seconds=round(now - started, 1), holders=busy, **origin)
    sys.exit(EXIT_TIMED_OUT)


def _acquire(slots, wait_seconds, poll, report_every, origin):
    """枠を 1 つ取る。取れた枠を返す。置き場を使えなければ None を返す。期限を越えたら抜ける。

    **窓つきの計測が順番待ちの印を握っている間は、空いた枠があっても取らない** (上の「## 窓つきの
    計測」)。取ると、検査が途切れない限り計測に順番が回ってこない。"""
    directory = _slot_dir()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        paths = [directory / f"slot-{index}.lock" for index in range(slots)]
        gate = directory / GATE_NAME
        started = time.monotonic()
        last_report = started
        while True:
            measuring = _gate_holder(gate)
            if measuring is None:
                for path in paths:
                    handle = _try_take(path)
                    if handle is not None:
                        waited = time.monotonic() - started
                        if waited >= report_every:
                            _say(f"枠 {path.name} を取った ({_span(waited)}待った)")
                        return handle
            now = time.monotonic()
            busy = ([measuring] if measuring else []) + _holders(paths)
            if now - started >= wait_seconds:
                _give_up(f"GPU の枠 ({slots}) ", "検査", wait_seconds, started, now, busy, origin)
            if now - last_report >= report_every:
                last_report = now
                if measuring:
                    _say(
                        f"窓つきの計測が GPU の枠を全部使う (取るのを待っている) 間は、検査を始めずに待つ — "
                        f"{_span(now - started)}経過 (期限 {_span(wait_seconds)})。相手:"
                    )
                else:
                    _say(
                        f"GPU の枠 ({slots}) が空くのを待っている — {_span(now - started)}経過"
                        f" (期限 {_span(wait_seconds)})。いま走っているもの:"
                    )
                for line in busy:
                    print(line, file=sys.stderr, flush=True)
            time.sleep(poll)
    except OSError as error:
        _say(f"枠の置き場 {directory} を使えないので、枠を取らずに走らせる ({error})")
        return None


def _acquire_all(slots, wait_seconds, poll, report_every, origin, command):
    """窓つきの計測のために、順番待ちの印と枠を全部取る。(印, [枠…]) を返す。置き場を使えなければ
    None を返す。期限を越えたら抜ける (取りかけた枠は、抜けたときに OS が外す)。

    **先に印を取る。** 取った後は普段の検査が新しく枠を取らないので、走っている検査が終わるのを
    待てば、枠は必ず全部空く。計測どうしは印で 1 本ずつになる。枠は空いたものから取る。"""
    directory = _slot_dir()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        paths = [directory / f"slot-{index}.lock" for index in range(slots)]
        gate_path = directory / GATE_NAME
        gate = None
        held = {}
        started = time.monotonic()
        last_report = started
        while True:
            if gate is None:
                gate = _try_take(gate_path, command)
            if gate is not None:
                for path in paths:
                    if path not in held:
                        handle = _try_take(path)
                        if handle is not None:
                            held[path] = handle
                if len(held) == len(paths):
                    waited = time.monotonic() - started
                    if waited >= report_every:
                        _say(f"枠を全部 ({slots}) 取った ({_span(waited)}待った)")
                    return gate, [held[path] for path in paths]
            now = time.monotonic()
            # 自分が握った枠は名乗らない (同じプロセスの別の開き口からは、握られているとしか読めない)
            other = None if gate is not None else _gate_holder(gate_path)
            busy = ([other] if other else []) + _holders([path for path in paths if path not in held])
            if now - started >= wait_seconds:
                _give_up(f"GPU の枠 ({slots}) の全部", "計測", wait_seconds, started, now, busy, origin)
            if now - last_report >= report_every:
                last_report = now
                waiting_for = "別の窓つきの計測" if gate is None else "GPU の検査"
                _say(
                    f"{waiting_for}が枠を握っているので、計測を始めずに待っている — "
                    f"{_span(now - started)}経過 (期限 {_span(wait_seconds)})。相手:"
                )
                for line in busy:
                    print(line, file=sys.stderr, flush=True)
            time.sleep(poll)
    except OSError as error:
        _say(f"枠の置き場 {directory} を使えないので、枠を取らずに計測を走らせる ({error})")
        return None


def _run(command, exclusive=False):
    environment = dict(os.environ)
    # 空の値は未設定と同じに扱う。Swift Testing が読めない値を素通しすると、縛りが黙って外れる
    if not environment.get(PARALLELIZATION_WIDTH_VARIABLE, "").strip():
        environment[PARALLELIZATION_WIDTH_VARIABLE] = DEFAULT_PARALLELIZATION_WIDTH
    if exclusive:
        # 子とその孫に「計測の内側で走っている」と知らせる。自分で包み直すスクリプトは、これを見て
        # 包み直さない。見ずに包み直すと、自分の親が握る枠を待ち続ける
        environment[EXCLUSIVE_VARIABLE] = str(os.getpid())
    child = subprocess.Popen(command, env=environment)

    def forward(signum, _frame):
        child.send_signal(signum)

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    code = child.wait()
    return 128 - code if code < 0 else code


def main(argv):
    exclusive = bool(argv) and argv[0] == "--exclusive"
    if exclusive:
        argv = argv[1:]
    if not argv or argv[0] != "--" or len(argv) < 2:
        _say("使い方: gpu-slot.py [--exclusive] -- <command…>")
        return EXIT_USAGE
    command = argv[1:]
    if exclusive and os.environ.get(EXCLUSIVE_VARIABLE):
        _say(f"既に窓つきの計測の内側 (pid {os.environ[EXCLUSIVE_VARIABLE]} が枠を全部握っている) なので、そのまま走らせる")
        return _run(command, exclusive=True)
    slots = _number("MOKUME_GPU_SLOTS", DEFAULT_SLOTS, integer=True)
    wait_seconds = _number("MOKUME_GPU_SLOT_WAIT", DEFAULT_WAIT_SECONDS, integer=False)
    poll = _number("MOKUME_GPU_SLOT_POLL", 2.0, integer=False)
    report_every = _number("MOKUME_GPU_SLOT_REPORT", 60.0, integer=False)
    origin = _origin()
    if exclusive:
        taken = _acquire_all(slots, wait_seconds, poll, report_every, origin, command)
        handles = [] if taken is None else [*taken[1], taken[0]]
        names = None if taken is None else [Path(handle.name).name for handle in taken[1]]
        _record("take", mode="exclusive", slots=names, command=command, **origin)
    else:
        slot = _acquire(slots, wait_seconds, poll, report_every, origin)
        handles = [] if slot is None else [slot]
        names = None if slot is None else Path(slot.name).name
        _record("take", slot=names, command=command, **origin)
    started = time.monotonic()
    code = None
    try:
        code = _run(command, exclusive=exclusive)
        return code
    finally:
        _record(
            "release", **({"mode": "exclusive", "slots": names} if exclusive else {"slot": names}),
            exit_code=code, seconds=round(time.monotonic() - started, 1),
        )
        # 枠を先に返し、順番待ちの印を最後に返す
        for handle in handles:
            handle.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
