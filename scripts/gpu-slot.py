#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""GPU の検査を、機械全体で共有する枠を 1 つ取ってから走らせる (#1898)。

    python3 scripts/gpu-slot.py -- swift test --skip-build …

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
**待つ側が期限を持つ** (AGENTS.md の「検査の待たないは待つ側が持つ」)。
`$MOKUME_GPU_SLOT_WAIT` 秒 (既定 5400 = 90 分) を越えたら、持ち主を名乗って 75 で抜ける。
全体の test 段は 6〜8 分 (並列の幅を縛った後・下の「## 並列の幅」) なので、枠 3 に 10 本並んでも 30 分ほどで回ってくる。90 分を越えて
待つのは、持ち主が固まっているときである。

## 枠を取れない環境

置き場を作れない・ロックできないときは、**枠を取らずに子を走らせ、そうしたことを 1 行で
名乗る**。黙って素通りはしない。検査の段を止める側には倒さない — 枠は検査の保証ではなく、
混雑の抑えだからである。

## 範囲の外

**素の `swift test` (全検査も `--filter …` も) は、この枠にも下の並列の幅にも届かない。範囲の
外と決めた (#2004)。** 縛りは、gpu-slot を通った実行にだけ掛かる。

素の実行が縛られていないことで起きた事故は、記録に無い。#1999 の 2 件のうち、カーネルパニックは
枠の内側の `make test-release` で起き、幅が無く 1 プロセスに発行口が並んだためで、下の並列の幅で
塞いだ。素の `--filter … --repeat-until` で WindowServer が止まったもう 1 件は、根が同じ suite の
中で `spin` が重なったことにあり、幅を掛けても防げなかった。そちらは suite の側で直した
(`.serialized` と、回転を残して返らない `settle()`)。残るのは、素の全検査では同時の発行口が
また上限なく並ぶ (debug で最大 248 本) という穴だけで、事故が出てから足す (ADR-0008)。

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
渡す。既定は 16 で、同時の発行口は 12 本に収まり、全体の所要は 1 割ほど延びた (366 → 401 秒)。
**呼ぶ側が環境に値を持っていれば、そちらを使う** (切り分けで幅を変えて走らせるための口)。空の値は
持っていないものとして扱う。

**口の名前に EXPERIMENTAL が付いている。** toolchain の更新で名前が変われば、Swift Testing は
知らない変数を読まないので、縛りは黙って外れる。幅の値と名前はここ 1 箇所にだけ置く。外れたかは、
全検査の同時の発行口が数十本を越えて戻ること (#1999 の計り方)、または同じ機械の全検査の重なりで
WindowServer が止まることで分かる。そのときは、toolchain の `Testing` の文字列から今の名前を引く。

## 起動元の記録

**枠を取った・返した・期限で抜けたときに、起動元を 1 行の JSON で追記する** (#2059)。置き場は
`$MOKUME_GPU_SLOT_LOG` (既定 `~/Library/Logs/mokume/gpu-slot.jsonl`)。枠のロックは次の持ち主に
上書きされるうえ、`pid / cwd / 時刻` しか持たない。#2052 のパニックでは、GPU を塞いだ全検査を
誰が起動したかを割り出すのに 1 時間かかった。正体は、エージェントのコマンドの引用符なしの heredoc
の中のバッククォートが、`make test-release` として実行されたものだった。記録には次を残す:

- `event` (`take` / `release` / `timeout`)・時刻・枠・自分の pid・cwd・子のコマンド・終了コード・所要
- `lineage`: 親プロセスを launchd の手前まで辿った各段の pid / ppid / 起動時刻 / コマンドラインの先頭。
  #2052 の形なら、ここに `zsh -c … python3 - <<EOF …` が載り、起動元がその場で分かる
- `agent`: 環境にあるエージェントの出所 (`CLAUDE_CODE_SESSION_ID`・`MOKUME_AGENT_NAME` など)

**書けなくても検査は止めない** (1 行名乗るだけ)。大きさが上限 (1 MB) を越えたら、新しい半分だけを残す。
キャッシュの置き場と分けるのは、消してよい場所に調査の記録を置かないためである。

**手元機が落ちた・画面が固まったときの読み方:**

1. `/Library/Logs/DiagnosticReports/` の `panic-full-*.panic` と `WindowServer_*.spin` を開く。
   `.spin` の `swiftpm-testing-helper` のうち、GPU のドライバの中で止まったスレッドを持つものを探す。
   起動時刻は、`.spin` の先頭の時刻から `Time Since Fork` を引けば出る
2. その時刻の前後の `take` を、この記録から引く。cwd (どの worktree か) で絞る
3. `lineage` のコマンドラインと `agent` から、起動したセッションを特定する。セッションの操作記録は
   `~/.claude/projects/<cwd を - で繋いだ名前>/<session_id>.jsonl` にある

**この記録に載らないもの:** 枠を通らない実行 (素の `swift test`・窓つきのスケッチ・`mokume watch`)。
GPU を使っていたのにここに無ければ、それは枠の外の実行である (上の「範囲の外」・#2052)。

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

# 並列の幅の口と既定 (上の「## 並列の幅」)
LOG_LIMIT_BYTES = 1_000_000
# Claude のシェルは先頭に snapshot の source を持つので、本題のコマンドまで届く長さにする
LINEAGE_COMMAND_CHARACTERS = 1000
# 起動元を名乗る環境変数。値が無いものは記録に載せない
AGENT_VARIABLES = (
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT",
    "MOKUME_AGENT_NAME",
    "CODEX_SESSION_ID",
    "CODEX_THREAD_ID",
)
PARALLELIZATION_WIDTH_VARIABLE = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
DEFAULT_PARALLELIZATION_WIDTH = "16"


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
    """自分から launchd の手前まで、親プロセスを辿る。各段の pid・ppid・起動時刻・コマンドラインを返す。"""
    chain = []
    pid = os.getpid()
    seen = set()
    while pid > 1 and pid not in seen and len(chain) < 32:
        seen.add(pid)
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,lstart=,command=", "-p", str(pid)],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            break
        # lstart は "Sun Oct  4 13:29:27 2026" の 5 語
        fields = out.split(None, 6)
        if len(fields) < 6 or not fields[0].isdigit():
            break
        parent = int(fields[0])
        chain.append({
            "pid": pid,
            "ppid": parent,
            "started": " ".join(fields[1:6]),
            "command": (fields[6] if len(fields) > 6 else "")[:LINEAGE_COMMAND_CHARACTERS],
        })
        pid = parent
    return chain


def _record(event, **fields):
    """起動元の記録へ 1 行追記する。書けなくても検査は止めない。"""
    path = _log_path()
    entry = {
        "event": event,
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "pid": os.getpid(),
        "cwd": os.getcwd(),
        **fields,
    }
    if event != "release":
        entry["lineage"] = _lineage()
        entry["agent"] = {name: os.environ[name] for name in AGENT_VARIABLES if os.environ.get(name)}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
            handle.flush()
            if handle.tell() > LOG_LIMIT_BYTES:
                _trim(path)
    except OSError as error:
        _say(f"起動元の記録 {path} に書けなかった ({error})。検査はそのまま走らせる")


def _trim(path):
    """上限を越えた記録を、新しい半分だけにする。呼ぶ側が排他のロックを持っている。"""
    data = path.read_bytes()
    keep = data[len(data) - LOG_LIMIT_BYTES // 2:]
    newline = keep.find(b"\n")
    keep = keep[newline + 1:] if newline >= 0 else b""
    temporary = path.with_name(path.name + ".trim")
    temporary.write_bytes(keep)
    os.replace(temporary, path)


def _try_take(path):
    """枠のファイルを 1 つ排他で取る。取れたら開いたままのファイルを、取れなければ None を返す。"""
    handle = open(path, "a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\t{os.getcwd()}\t{int(time.time())}\n")
    handle.flush()
    return handle


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


def _acquire(slots, wait_seconds, poll, report_every):
    """枠を 1 つ取る。取れた枠を返す。置き場を使えなければ None を返す。期限を越えたら抜ける。"""
    directory = _slot_dir()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        paths = [directory / f"slot-{index}.lock" for index in range(slots)]
        started = time.monotonic()
        last_report = started
        while True:
            for path in paths:
                handle = _try_take(path)
                if handle is not None:
                    waited = time.monotonic() - started
                    if waited >= report_every:
                        _say(f"枠 {path.name} を取った ({_span(waited)}待った)")
                    return handle
            now = time.monotonic()
            if now - started >= wait_seconds:
                _say(
                    f"GPU の枠 ({slots}) が {_span(wait_seconds)}空かなかったので、検査を走らせずに抜ける。"
                    " 持ち主が固まっていないか確かめる (MOKUME_GPU_SLOT_WAIT で期限を変えられる):"
                )
                for line in _holders(paths):
                    print(line, file=sys.stderr, flush=True)
                _record("timeout", waited_seconds=round(now - started, 1), holders=_holders(paths))
                sys.exit(EXIT_TIMED_OUT)
            if now - last_report >= report_every:
                last_report = now
                _say(
                    f"GPU の枠 ({slots}) が空くのを待っている — {_span(now - started)}経過"
                    f" (期限 {_span(wait_seconds)})。いま走っているもの:"
                )
                for line in _holders(paths):
                    print(line, file=sys.stderr, flush=True)
            time.sleep(poll)
    except OSError as error:
        _say(f"枠の置き場 {directory} を使えないので、枠を取らずに走らせる ({error})")
        return None


def _run(command):
    environment = dict(os.environ)
    # 空の値は未設定と同じに扱う。Swift Testing が読めない値を素通しすると、縛りが黙って外れる
    if not environment.get(PARALLELIZATION_WIDTH_VARIABLE, "").strip():
        environment[PARALLELIZATION_WIDTH_VARIABLE] = DEFAULT_PARALLELIZATION_WIDTH
    child = subprocess.Popen(command, env=environment)

    def forward(signum, _frame):
        child.send_signal(signum)

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    code = child.wait()
    return 128 - code if code < 0 else code


def main(argv):
    if not argv or argv[0] != "--" or len(argv) < 2:
        _say("使い方: gpu-slot.py -- <command…>")
        return EXIT_USAGE
    slots = _number("MOKUME_GPU_SLOTS", DEFAULT_SLOTS, integer=True)
    wait_seconds = _number("MOKUME_GPU_SLOT_WAIT", DEFAULT_WAIT_SECONDS, integer=False)
    poll = _number("MOKUME_GPU_SLOT_POLL", 2.0, integer=False)
    report_every = _number("MOKUME_GPU_SLOT_REPORT", 60.0, integer=False)
    slot = _acquire(slots, wait_seconds, poll, report_every)
    slot_name = Path(slot.name).name if slot is not None else None
    _record("take", slot=slot_name, command=argv[1:])
    started = time.monotonic()
    code = None
    try:
        code = _run(argv[1:])
        return code
    finally:
        _record("release", slot=slot_name, exit_code=code, seconds=round(time.monotonic() - started, 1))
        if slot is not None:
            slot.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
