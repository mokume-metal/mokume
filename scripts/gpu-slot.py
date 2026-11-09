#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""GPU のテストを、マシン全体で共有する枠を 1 つ取ってから走らせる (#1898)。ウィンドウつきの計測は、
枠を全部取ってから走らせる (#2052・下の「## ウィンドウつきの計測」)。

    python3 scripts/gpu-slot.py -- swift test --skip-build …
    python3 scripts/gpu-slot.py --exclusive -- <計測のコマンド…>

**同じマシンで GPU のテストが同時に走るのは、枠の数 (既定 3) までにする。** 複数のセッション
(並行する実装レーン) が `make test` を同時に回すと、GPU の資源切れ (`Cannot create a command
queue`・`kIOGPUCommandBufferCallbackErrorOutOfMemory`) で、変更と関係の無い suite が数百件
単位で失敗した (#1898 の表。5〜7 本が重なった回)。2〜3 本なら全体のテストは 1 回で通った。
並べる数をレーンをまとめる側の判断で抑えるだけでは、レーンからも別のセッションからも見えず、守られる
保証が無い。そこで、`swift test` を走らせる所で縛る。

## 枠

- 置き場は `$MOKUME_GPU_SLOT_DIR` (既定 `~/Library/Caches/mokume/gpu-slots`)。`TMPDIR` は
  セッションやツールによって差し替えられうるので使わない — 置き場が分かれると枠も分かれる
- 枠は `slot-0.lock` から数えた N 個のファイルで、`fcntl.flock` の排他ロックを 1 つ取る。
  数は `$MOKUME_GPU_SLOTS` (既定 3・1 以上の整数)
- **枠はこのプロセスが終われば返る。** クラッシュしても殺されても OS が外すので、後片付けは要らない。
  ロックは子へ継がせない (Python の既定)。子が孫を残しても、枠を握り続けることはない
- 取れたら、ファイルへ持ち主 (PID・作業ツリー・始めた時刻) を書く。待つ側がそれを表示する

## 待つ

空きが無ければ、数秒おきに取り直す。1 分おきに、何本がどこで走っているかを表示する。
**待つ側がタイムアウトを持つ** (AGENTS.md「場面別の入口」の「待ちを含むテストを書く」)。
`$MOKUME_GPU_SLOT_WAIT` 秒 (既定 5400 = 90 分) を越えたら、持ち主を表示して 75 で抜ける。
全体の test ターゲットは 6〜8 分 (並列の幅を縛った後・下の「## 並列の幅」) なので、枠 3 に 10 本並んでも 30 分ほどで回ってくる。90 分を越えて
待つのは、持ち主が固まっているときである。

## 枠を取れない環境

置き場を作れない・ロックできないときは、**枠を取らずに子を走らせ、そうしたことを 1 行で
表示する**。黙って素通りはしない。テストのターゲットを止める側には寄せない — 枠はテストの保証ではなく、
混雑の抑えだからである。

## ウィンドウつきの計測

**ウィンドウつきの計測と GPU のテストは、同じマシンで同時に走らせない** (#2052・メンテナの判断 2026-10-04)。
ウィンドウつきの計測とは、mokume のスケッチをウィンドウつきで動かして性能や挙動を測る実行である。#2052 では、
枠の外でウィンドウつきの計測 (ウィンドウ 最大 8 枚・3840×2160・録画つき) が走っている間に、枠の内側のテストが GPU を
詰まらせ、手元のマシンがカーネルパニックでクラッシュした。計測の負荷だけでは止まらなかった (#2052 の再現の
コメント) が、重なった場合については何も言えない。だから重ねない。

- `--exclusive` は、まず順番待ちのマーカー (置き場の `exclusive.lock`) を取る。次に枠を全部
  (`$MOKUME_GPU_SLOTS` 個) 取ってから、子を走らせる。テストが 1 本でも枠を握っていれば、空くまで待つ
- **マーカーが握られている間は、普段の実行は空いた枠があっても新しく取らない。** 計測が待っている間に
  後から来たテストが枠を取ると、テストが途切れない限り、計測に順番が回ってこない。マーカーを知らない古いバージョンの
  gpu-slot (他の作業ツリー) も、枠が全部埋まっているので待つ。計測どうしはマーカーで 1 本ずつになる
- 待ちのタイムアウト (`$MOKUME_GPU_SLOT_WAIT`)・表示・起動元の記録は普段と同じである。待つ側は相手を
  表示する (計測なら、マーカーに書いたコマンドの先頭も)。記録の `take` には `"mode": "exclusive"` と、
  取った枠の一覧が載る
- 子には `MOKUME_GPU_SLOT_EXCLUSIVE` (ラッパーの pid) を渡す。自分でラップし直すスクリプトは、これを見て
  ラップし直さない。内側でもう一度 gpu-slot を通しても (`--exclusive` でも、計測の中で実行した `make test`
  のような普段の実行でも)、枠を取らずにそのまま走らせる。枠は祖先が全部握っているので、取りに行くと
  自分の祖先をタイムアウトまで待ち続ける
- **ビルドはラップする前に済ませる。** ビルドの間も枠を握ると、テストを待たせるだけになる

このリポジトリでは、`scripts/measure-frame-rate.sh` と `scripts/check-observation-roundtrip.sh` が、
自分で `--exclusive` の内側へ入り直す。

**外から計測するとき** (probes など、このリポジトリの外のツールで mokume のスケッチをウィンドウつきで測る
とき) は、同じマシンにある mokume の作業ツリーのこのスクリプトで、計測のコマンドをラップする。枠の置き場は
既定のまま (`MOKUME_GPU_SLOT_DIR` を変えない) にする。変えると枠が分かれて、テストと重なる:

    swift build -c release        # ビルドは包む前に
    python3 <mokume の作業ツリー>/scripts/gpu-slot.py --exclusive -- <計測のコマンド…>

**ラップしないもの:** 普段のスケッチの実行 (`mokume watch`・作品の起動)。作り手の実行を、テストの都合で
待たせない。

## 期限切れの記録 (#2235)

**GPU の待ちがタイムアウトを越えたプロセスは、その旨を置き場へ 1 つ残す。次のテスト・計測は、それを表示して
始めずに止まる。** 待ちがタイムアウト (`RenderDevice.waitLimitSeconds`・5 秒) を越えたプロセスは、以後
新しいコマンドキューを作らない (`CommandQueueGate`・#2052) が、そのマーカーはプロセスの中にしか無い。害 (WindowServer
の watchdog によるカーネルパニック) はマシン全体に及ぶので、テストが終わって枠が返ると、待っていた別の
テストプロセスが新しいゲートで、まだ応答しない GPU にコマンドキューを作り、止まったコマンドキューがまた溜まる。

- 記録は `$MOKUME_GPU_SLOT_DIR` の `wait-expired.json` (枠のロックと同じ場所)。時刻・pid・cwd・
  どの待ちがどのタイムアウトを越えたか、と、起動元 (`lineage`・`agent`。「## 起動元の記録」と同じ項目) が入る。
  書くのは Swift の側 (`ExpiryRecord`) で、**このラッパーの下で走っているときだけ**書く。ラッパーが子へ
  `MOKUME_GPU_SLOT_EXPIRY_RECORD` (記録のパス) と `MOKUME_GPU_SLOT_PID` (ラッパーの pid) を渡し、
  渡されていなければ (利用者のスケッチ・`mokume run` ほか) 何も書かない。起動元は子から取得できないので、
  書いた子のラッパーが、子が終わった後に追加する
- **枠を取る前に記録があれば、記録の中身と、人が何を確かめてから消すかを表示し、子を起動せずに 76 で
  抜ける** (タイムアウトの 75 とは別)。`--exclusive` も同じである。枠を待つ間に別のプロセスがタイムアウトを越える
  こともあるので、**枠を取れた後にもう一度見て**、あれば枠を返して止まる。計測の内側で起動した
  このラッパー (`MOKUME_GPU_SLOT_EXCLUSIVE` が立っているとき) も、枠は取らないが、記録は見て止まる —
  1 つの計測が何本も起動するので、2 本目以降が応答しない GPU にコマンドキューを作らないように
- **記録は手で消すまで残る。** 時間や回数で解除する形は採らない — GPU が応答するようになったかを確かめる
  には、コマンドキューに仕事を投入して待つほかなく、それ自体が応答しない GPU への追加の投入になるから
  (`CommandQueueGate` のマーカーが一方向なのと同じ理由)。**消すのは人で、確かめてからである**: 画面が固まって
  いない・前のテストプロセスが残っていない・GPU が応答する。止まるときのメッセージは何を確かめるかを先に言い、記録の
  場所を示すだけにする (そのまま実行できる削除の 1 行は出さない — 読んだエージェントが、確かめずに消す)
- **記録は、起動された後のプロセスにも効く。** このラッパーが記録を読むのは起動するときだけだが、`MOKUME_GPU_SLOT_
  EXPIRY_RECORD` を渡されたプロセスのゲート (Swift の `CommandQueueGate`) は、新しいコマンドキューを作る前に記録の
  有無を見て、あれば作らない。ラップした実行の中で後から起動される子 (exit test の子・`mokume watch` の世代) と、
  既に走っている別の枠のテストは、これで止まる。**ゲートに記録を持たせるのは、このラッパーの下で走るプロセス
  だけ**で、書きも読みもする
- **古いバージョンの `gpu-slot.py` (他の作業ツリー) は、記録を読まない。** 記録を知らないバージョンが起動するテストは止まらない
  (子へ書き先も渡さないので、そのテストは記録も書かない)。順番待ちのマーカー (`exclusive.lock`) を知らないバージョンを
  「## ウィンドウつきの計測」が認めているのと同じ、作業ツリーのバージョンが揃うまでの形である。記録を読むバージョンを取り込めば
  その作業ツリーも止まるので、マシンの中のバージョンが揃うほど守りは強くなる
- **範囲の外:** 枠を通らない実行 (素の `swift test`・`make reference-shots`・`make example-shots`・
  エージェントが起動する `mokume watch` など) は、このラッパーも渡さないので書きも読みもしない (下の「範囲の外」)

## 範囲の外

**素の `swift test` (全テストも `--filter …` も) は、この枠にも下の並列の幅にも届かない。範囲の
外と決めた (#2004)。** 縛りは、gpu-slot を通った実行にだけ掛かる。

素の実行が縛られていないことで起きた事故は、記録に無い。#1999 の 2 件のうち、カーネルパニックは
枠の内側の `make test-release` で起き、幅が無く 1 プロセスにコマンドキューが並んだためで、下の並列の幅で
塞いだ。素の `--filter … --repeat-until` で WindowServer が止まったもう 1 件は、根本原因が同じ suite の
中で `spin` が重なったことにあり、幅を掛けても防げなかった。そちらは suite の側で直した
(`.serialized` と、回転を残して返らない `settle()`)。残るのは、素の全テストでは同時のコマンドキューが
また上限なく並ぶ (debug で最大 248 本) という穴と、幅が無いことで #2007 の打ち切り (幅 4 以上で出る。
失敗するだけで、WindowServer は止めない) も起きうることで、事故が出てから足す (ADR-0008)。

**絞った実行は、gpu-slot を前置して実行する** (枠も幅も掛かる):

    python3 scripts/gpu-slot.py -- swift test --filter …

`make test` に絞り込みの手段は無い。ビルドの指定が `make` と違えば再ビルドが起きうる (Makefile の
`SYMBOL_GRAPH_FLAGS` の節)。

**枠の外のまま残す実行が 1 つある。** ShadowTests の負荷の手順は、重なりを作って遅れをあぶり出す
検出器なので、わざと 6 本を同時に走らせる。gpu-slot を前置すると 3 本ずつに下がり、検出力だけが
落ちる。この規則の例外の置き場は、その手順の上である。

**縛りを足すのは、次のどちらかが起きたとき**: 素の実行で WindowServer が止まる・パニックが起きる
/ 下の並列の幅の手段が効いていないと分かる。足すなら、縛る単位は `RenderDevice(` の呼び出し
(Tests に 400 余り) ではなく、suite の `TestScoping` の trait である。`RenderDevice.init` は
同期で `@MainActor` なので、中で待つと、テストが全部載っている main actor ごと止まる。GPU の suite
には `.enabled(if: RenderDevice.isAvailable, …)` が付いていて、`GPUGateTests` がその付け忘れを
見ているので、trait はそこへ並べる。

## 並列の幅

**枠が縛るのはプロセスの数で、1 プロセスの中で同時に進むテストの数は縛らない。** Swift Testing は
GPU を待って止まった非同期のテストを上限なく並べ、それぞれが自分の `RenderDevice` (コマンドキュー
1 本) を持つ。debug の全テストの 1 プロセスで、同時に生きるコマンドキューは最大 248 本あった。
GPU は画面の描画 (WindowServer) と共有なので、全テストが重なって GPU が詰まると WindowServer が
ドライバの中で待たされ、watchdog が手元のマシンごとクラッシュさせる (#1999。カーネルパニックまで行った)。

そこで、子へ `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` (Swift Testing の並列の幅) を
渡す。**既定は 1 である。** 最初は 16 にしていた (#1999。同時のコマンドキューは 12 本に収まり、全体の所要は
1 割ほど延びた = 366 → 401 秒)。**呼ぶ側が環境に値を持っていれば、そちらを使う** (切り分けで幅を
変えて走らせるための手段)。空の値は持っていないものとして扱う。

**1 にした理由 (#2007)。** 専用機で `EffectArgumentTests` だけを回すと、幅 4・16・100000 では
30 回中 7〜15 回で、GPU の仕事が `kIOGPUCommandBufferCallbackErrorPageFault` か `ErrorHang` で
打ち切られた。幅 1 では 30 回で 0 だった (2・3 は測っていない)。全テストでも、#2008 以降の専用機の
7 本中 6 本で出て、幅 1 では 2 回で 0 だった。`MTL4CommandQueue` (= `RenderDevice`) を解放しない・
遅らせる・使い回す・解放の後に 200ms 待つ、のどれでも消えたので、引き金はキューの解放の周りにある。
テストは main actor で直列に走る (`Package.swift` の既定の隔離) ので、幅 1 でも全体の所要は変わらない
(専用機の全テストで、幅 16 が 287〜288 秒、幅 1 が 285〜286 秒)。

**引き金は、幅ではなく `RenderDevice` の側でずらした (#2054)。** 幅 1 でも、全テストでは解放の直後の
打ち切りが残っていた。専用機の計測では 6 回中 4 回で、#2251 の定期のテストの失敗もこれだった。`RenderDevice` が
手放したコマンドキューは、すぐには解放せず、ゲートが後から 8 本手放されるまで持つ
(`Sources/MokumeCore/Rendering/CommandQueueGate.swift` の「手放した発行口の解放を遅らせる」)。
遅らせた形は全テストで 5 回中 0 回だった。
- **根本原因は直していない。** 根本原因は Metal の側にあって見えない。解放しない対照でも、幅 16 の
  `EffectArgumentTests` では 30 回中 1 回が残ったので、別の根本原因があるかもしれない。標本も小さく、
  5 回の 0 は、95% で上限が約 45% にしか絞れない。製品のコードパスで起きるかは確かめていない
- **幅 1 の既定は残す。** 1 つは、同時のコマンドキューを抑えて #1999 (全テストの重なりで GPU が詰まり、
  WindowServer ごとクラッシュする) を避けるため。もう 1 つは、広げても割に合わないためである。GPU の無い
  ホストの `ci-check` で幅 8 を試したところ (#3196)、テストの実行は 587 秒から 422〜529 秒に縮んだが、
  3 回目に、待ちにタイムアウトを持つネットワークのテストが 14 本、3 コアの競合で失敗した
- **幅 1 では塞げなかった経路がある**: GPU が応答しなくなった後、`RenderDevice.waitLimitSeconds` で待ちを
  打ち切って `RenderDevice` を破棄し、次のテストが新しいキューを作り続けて、止まったキューが溜まる (#2052)。これは
  幅ではなく `RenderDevice` の側で塞いだ。待ちが一度タイムアウトを越えたプロセスでは、新しいキューを作らない
  (`Sources/MokumeCore/Rendering/CommandQueueGate.swift`)
- **測っていないのは**、手元のマシン (M3 Max) の所要と、幅 1 での同時のコマンドキューの数 (テストが 1 本ずつなので
  1 本前後のはず) である

**変数の名前に EXPERIMENTAL が付いている。** toolchain の更新で名前が変われば、Swift Testing は
知らない変数を読まないので、縛りは黙って外れる。幅の値と名前はここ 1 箇所にだけ置く。外れたかは、
専用機の全テストで `The GPU dropped the work` (`ErrorPageFault` / `ErrorHang`) が戻ること (幅 16 のときの
症状・#2007)、全テストの同時のコマンドキューが数十本を越えて戻ること (#1999 の計り方)、または同じマシンの全テストの
重なりで WindowServer が止まることで分かる。そのときは、toolchain の `Testing` の文字列から今の名前を
探す。

## 起動元の記録

**枠を取った・返した・タイムアウトで抜けたときに、起動元を 1 行の JSON で追記する** (#2059)。置き場は
`$MOKUME_GPU_SLOT_LOG` (既定 `~/Library/Logs/mokume/gpu-slot.jsonl`)。枠のロックは次の持ち主に
上書きされるうえ、`pid / cwd / 時刻` しか持たない。#2052 のパニックでは、GPU を塞いだ全テストを
誰が起動したかを割り出すのに 1 時間かかった。正体は、エージェントのコマンドの引用符なしの heredoc
の中のバッククォートが、`make test-release` として実行されたものだった。記録には次を残す:

- `event` (`take` / `release` / `timeout`)・時刻・枠・自分の pid・cwd・子のコマンド・終了コード・所要
- `lineage`: 親プロセスを launchd の手前まで辿った各段階の pid / ppid / 起動時刻 / コマンドラインの先頭。
  枠を待つ前に取る。#2052 の形なら、ここに `zsh -c … python3 - <<EOF …` の先頭が載る。ただし
  コマンドが長ければ、実行されてしまった箇所は切った先にありうる (各段階 4000 字まで)
- `agent`: 環境にあるエージェントの出所 (`CLAUDE_CODE_SESSION_ID`・`MOKUME_AGENT_NAME` など)

**書けなくてもテストは止めない** (1 行表示するだけ)。行ごとにディスクまで書き出す (パニックの直前の行が
いちばん欲しい)。大きさが上限 (4 MB) を越えたら、同じファイルの中で新しい半分だけを残す。
キャッシュの置き場と分けるのは、消してよい場所に調査の記録を置かないためである。

**手元のマシンが落ちた・画面が固まったときの読み方:**

1. `/Library/Logs/DiagnosticReports/` の `panic-full-*.panic` と `WindowServer_*.spin` を開く。
   `.spin` の `swiftpm-testing-helper` のうち、GPU のドライバの中で止まったスレッドを持つものを探す。
   起動時刻は、`.spin` の先頭の時刻から `Time Since Fork` を引けば出る
2. その時刻の前後の `take` を、この記録から探す。cwd (どの worktree か) で絞る
3. `lineage` のコマンドラインと `agent` から、起動したセッションを特定する。Claude のセッションの操作
   記録は `find ~/.claude/projects -name '<CLAUDE_CODE_SESSION_ID>.jsonl'` で見つけられる (置き場の名前は
   セッションを始めたときの cwd から作られ、gpu-slot の cwd とずれうる)。その時刻の Bash の
   tool_use を読めば、何を実行して起動したかが分かる

**この記録に載らないもの:** 枠を通らない実行 (素の `swift test`・ShadowTests の負荷の手順・
`make reference-shots`・ラップせずに起動したウィンドウつきのスケッチ・`mokume watch`)。GPU を使っていたのに
ここに無ければ、それは枠の外の実行である (上の「範囲の外」・#2052)。ウィンドウつきの計測は、ラップしていれば
`"mode": "exclusive"` の行で載る (上の「## ウィンドウつきの計測」)。

終了コードは、子のものをそのまま返す。ラッパー自身が返すのは、使い方の誤り (2)・枠を待つタイムアウト (75)・
期限切れの記録で止まったとき (76) である。SIGINT / SIGTERM は子へ渡す。取り直しの間隔
(`$MOKUME_GPU_SLOT_POLL` 秒) と表示する間隔 (`$MOKUME_GPU_SLOT_REPORT` 秒) は、テストが短く回す
ための手段である。テストは scripts/tests/gpu_slot_test.py。
"""

import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_SLOTS = 3
DEFAULT_WAIT_SECONDS = 5400
EXIT_TIMED_OUT = 75
EXIT_USAGE = 2
# 期限切れの記録があって、起こさずに止まった (上の「## 期限切れの記録」)
EXIT_GPU_STUCK = 76

# 期限切れの記録 (#2235)。置き場のファイル名と、子へ渡す環境変数 (Swift の `ExpiryRecord` と揃える)
EXPIRY_NAME = "wait-expired.json"
EXPIRY_VARIABLE = "MOKUME_GPU_SLOT_EXPIRY_RECORD"
WRAPPER_VARIABLE = "MOKUME_GPU_SLOT_PID"

# ウィンドウつきの計測 (上の「## ウィンドウつきの計測」)。順番待ちの印のファイル名と、子へ渡す「内側で走っている」の印
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
        return f"  - ウィンドウつきの計測 ({GATE_NAME}): pid {record[0]} · {record[1]} · {minutes} 分前から · {record[3]}"
    return f"  - ウィンドウつきの計測 ({GATE_NAME}): 持ち主を読めない"


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

    **ウィンドウつきの計測が順番待ちの印を握っている間は、空いた枠があっても取らない** (上の「## ウィンドウ
    つきの計測」)。取ると、検査が途切れない限り計測に順番が回ってこない。"""
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
                        f"ウィンドウつきの計測が GPU の枠を全部使う (取るのを待っている) 間は、検査を始めずに待つ — "
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
    """ウィンドウつきの計測のために、順番待ちの印と枠を全部取る。(印, [枠…]) を返す。置き場を使えなければ
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
                waiting_for = "別のウィンドウつきの計測" if gate is None else "GPU の検査"
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


def _expiry_path():
    return _slot_dir() / EXPIRY_NAME


def _read_expiry():
    """期限切れの記録を読む。無ければ None、あれば (パス, 中身) を返す。中身が読めない (JSON でない・
    権限が無い) ときは、中身を None にして返す — **在るのに読めない記録を、無いものとして素通ししない**。
    置き場そのものを使えないとき (枠も取れない環境) は、無いものとして扱う。"""
    path = _expiry_path()
    try:
        status = os.lstat(path)
    except OSError:
        # 無い。置き場そのものを使えないとき (枠も取れない環境) も、無いものとして扱う
        return None
    # **リンクは辿らない。** Swift の関所 (`ExpiryRecord.exists`・lstat) と前検査 (`-L`) は、壊れたリンクも
    # 生きたリンクも「在る」と数える。辿ると、壊れたリンクを「無い」と読んで子を起こし、関所が止める記録を
    # この包みが素通しする。普通のファイルでないものは、読めない記録として止める
    if not stat.S_ISREG(status.st_mode):
        return path, None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return path, None
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    return path, data if isinstance(data, dict) else None


def _refuse_for_expiry(found, subject, origin=None):
    """期限切れの記録があるので、起こさずに止まる。記録の中身と、人が確かめることを名乗り、76 を返す。

    **消すためのそのまま打てる 1 行は出さない** (上の「## 期限切れの記録」)。読んだエージェントが、確かめずに消す。"""
    path, data = found
    _say(
        f"GPU の待ちが期限を越えた記録があるので、{subject}を走らせずに抜ける (終了コード {EXIT_GPU_STUCK})。"
        "前の実行が止めた GPU は、まだ答えないかもしれない:"
    )
    if data is not None:
        waited = data.get("wait", "?")
        print(
            f"  - {data.get('time', '?')} · pid {data.get('pid', '?')} · {data.get('cwd', '?')}"
            f" · 待ち: {waited} (期限 {data.get('limit', '?')})",
            file=sys.stderr, flush=True,
        )
        print(f"  (起動元は記録の lineage・agent と、{_log_path()} の take の行にある)", file=sys.stderr, flush=True)
    else:
        print("  - 記録の中身を読めない", file=sys.stderr, flush=True)
    print(
        "  記録は人が確かめてから消す (時間では下りない)。確かめること: 画面が固まっていない・前の検査プロセスが"
        " 残っていない (`bash scripts/orphan-processes.sh`)・GPU が答える。確かめる前に消して続けると、"
        "答えない GPU に新しい発行口を作って、機械ごと止まりうる。",
        file=sys.stderr, flush=True,
    )
    print(f"  記録のファイル: {path}", file=sys.stderr, flush=True)
    if origin is None:
        origin = _origin()
    _record("refused", reason="wait-expired", expiry_record=str(path), expiry=data, **origin)
    return EXIT_GPU_STUCK


def _fullsync(descriptor):
    """ディスクまで落とす (macOS の `fsync` はドライブのキャッシュに留まりうるので `F_FULLFSYNC` を試す)。"""
    try:
        fcntl.fcntl(descriptor, fcntl.F_FULLFSYNC)
    except (AttributeError, OSError):
        os.fsync(descriptor)


def _complete_expiry(origin):
    """自分の子が書いた期限切れの記録に、起動元と包みのコマンドを足す。子は親プロセスの連鎖を引けない
    ので、ここで足す。足せなくても (包みごと殺された・書けない) 記録は残り、起動元は `take` の行から引ける。
    **何が起きても例外を外へ出さない。**"""
    try:
        path = _expiry_path()
        if not stat.S_ISREG(os.lstat(path).st_mode):
            return  # リンクは辿らない (自分の子が書いたのは普通のファイル)
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("gpu_slot_pid") != os.getpid() or "lineage" in data:
            return
        data.update(origin)
        # 置き換えは同じ置き場の中で (別のファイルシステムをまたがない)
        temporary = path.with_name(f".{path.name}.{os.getpid()}")
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            try:
                os.write(descriptor, (json.dumps(data, ensure_ascii=False) + "\n").encode("utf-8"))
                _fullsync(descriptor)
            finally:
                os.close(descriptor)
            # **置き換えの直前に、記録がまだ在るかを確かめる。** 読んでから置き換えるまでの間に人が消した
            # (GPU が答えると確かめて消した) 記録を、起動元つきで書き戻すと、消したはずの記録が戻る
            if not os.path.lexists(path):
                return
            os.replace(temporary, path)
        finally:
            try:
                os.unlink(temporary)  # 置き換えた後は無い。置き換えなかったときの下書きを残さない
            except OSError:
                pass
    except Exception:
        pass


def _run(command, exclusive=False, own=True):
    environment = dict(os.environ)
    # 期限切れの書き先と包みの pid を子へ渡す (上の「## 期限切れの記録」)。pid は、自分の子の記録かを
    # 包みが見分けるためで、内側の素通しの包み (own=False) は外側のものを残す
    environment[EXPIRY_VARIABLE] = str(_expiry_path().absolute())
    if own:
        environment[WRAPPER_VARIABLE] = str(os.getpid())
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
    if os.environ.get(EXCLUSIVE_VARIABLE):
        # 祖先の --exclusive が順番待ちの印と枠を全部握っている。--exclusive でも普段の実行
        # (計測の内側で打った make test) でも、取りに行けば自分の祖先を期限まで待つことになる
        # 枠は取らない。**記録は見る** — 1 つの計測が何本も起こすので、2 本目以降が答えない GPU に発行口を作る
        found = _read_expiry()
        if found:
            return _refuse_for_expiry(found, "計測の内側の" + ("計測" if exclusive else "検査"))
        _say(f"既にウィンドウつきの計測の内側 (pid {os.environ[EXCLUSIVE_VARIABLE]} が枠を全部握っている) なので、そのまま走らせる")
        return _run(command, exclusive=exclusive, own=False)
    slots = _number("MOKUME_GPU_SLOTS", DEFAULT_SLOTS, integer=True)
    wait_seconds = _number("MOKUME_GPU_SLOT_WAIT", DEFAULT_WAIT_SECONDS, integer=False)
    poll = _number("MOKUME_GPU_SLOT_POLL", 2.0, integer=False)
    report_every = _number("MOKUME_GPU_SLOT_REPORT", 60.0, integer=False)
    # 前の実行が期限切れを残していたら、枠を待つ前に止まる (上の「## 期限切れの記録」)
    subject = "計測" if exclusive else "検査"
    found = _read_expiry()
    if found:
        return _refuse_for_expiry(found, subject)
    origin = _origin()
    if exclusive:
        taken = _acquire_all(slots, wait_seconds, poll, report_every, origin, command)
        handles = [] if taken is None else [*taken[1], taken[0]]
        names = None if taken is None else [Path(handle.name).name for handle in taken[1]]
    else:
        slot = _acquire(slots, wait_seconds, poll, report_every, origin)
        handles = [] if slot is None else [slot]
        names = None if slot is None else Path(slot.name).name
    # 枠を待つ間 (最長 $MOKUME_GPU_SLOT_WAIT) に、別のプロセスが期限を越えたかもしれない。起こす前にもう一度見る
    found = _read_expiry()
    if found:
        for handle in handles:
            handle.close()
        return _refuse_for_expiry(found, subject, origin)
    if exclusive:
        _record("take", mode="exclusive", slots=names, command=command, **origin)
    else:
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
        _complete_expiry(origin)
        # 枠を先に返し、順番待ちの印を最後に返す
        for handle in handles:
            handle.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
