<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` をスケッチでない場所 (`Package.swift` の無い場所) で `MOKUME_WORK_DIR` なしに立てたとき、走っているスケッチが応えない答えに 4 つ目の可能性として `This interface was not started in a sketch's directory` と、その場所に `Package.swift` が無いこと、`mokume mcp <sketch directory>` で起こし直す手が出るようになった ([#2487](https://github.com/mokume-metal/mokume/issues/2487))。`claude mcp add mokume -- mokume mcp` は起こされた場所で窓口を立てるので、スケッチの外で立てると自分の場所で走るスケッチと噛み合わないのに、これまでは場所を渡す手を言わなかった。同じ答えの 1 つ目 (起動し直す) もその場所の話として言い直し、2 つ目 (区画の基準が割れている) には、`MOKUME_WORK_DIR` が無ければ「窓口をスケッチの場所で起こす」手が常に載る。区画を置けなかったとき・作り直しの記録が無いとき (`build_status`)・公開 API の一覧の版が引けないとき (`reference` の `api`) の答えにも同じ手が添えられる。`MOKUME_WORK_DIR` があるときは区画の基準が場所に依らないので、4 つ目は出ない。

`watch`・`doctor`・窓口が名乗る区画の基準の 1 行は、`MOKUME_WORK_DIR` が無いとき `using the sketch's own directory` ではなく `using the directory it was started for` と言うようになった。窓口と `doctor` はスケッチでない場所でも立つため。区画 (`.mokume/`) はこれまでどおりその場所に作る — 組み上げた実行ファイルをその場所から起こした使い方は、そこで正しく繋がるため。
