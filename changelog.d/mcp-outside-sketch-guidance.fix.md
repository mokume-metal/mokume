<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` をスケッチでない場所 (`Package.swift` の無い場所) で立てたとき、走っているスケッチが応えない答えに 4 つ目の可能性として `This interface was not started in a sketch's directory` と、その場所に `Package.swift` が無いこと、`mokume mcp <sketch directory>` で起こし直す手が出るようになった ([#2487](https://github.com/mokume-metal/mokume/issues/2487))。`claude mcp add mokume -- mokume mcp` は打った場所で窓口を起こすので、スケッチの外で立てると別の場所で走るスケッチと噛み合わないのに、これまでは 3 つの可能性だけを答えて場所を渡す手を言わなかった。作り直しの記録が無いとき (`build_status`) と、公開 API の一覧の版が引けないとき (`reference` の `api`) の答えにも同じ手が添えられる。スケッチの場所で立てた窓口の答えは変わらない。区画 (`.mokume/`) はこれまでどおりその場所に作る — 組み上げた実行ファイルをその場所から起こした使い方は、そこで正しく繋がるため。
