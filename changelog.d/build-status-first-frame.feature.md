<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

見張り (`mokume watch`) の作り直しの記録 (`.mokume/build/status.json`) に、**差し替えを始めてから新しい絵が窓に出るまで**の所要時間 `timings.firstFrameMs` が載るようになった。これまでの `relaunchMs` は新しいスケッチを起こし終えた時点で止まっていて、作者が実際に待つ「新しい絵が出るまで」はどこにも測られていなかった。気付いてから新しい絵が出るまでは `detectMs + buildMs + firstFrameMs` で、`firstFrameMs` は `relaunchMs` を含む。

窓を出せた見張りだけが書き、窓が乗り換えを知らせた後に記録を書き直して足す。どの世代の絵か区別できない回 (最初の世代や、前の世代がまだ出ないうちに差し替えた回) は、嘘の数字を書かずに省く。あわせて `detectMs` の説明を実装どおり「変化に気付いてから作り直しを始めるまで」へ直した (値は変わっていない)。
