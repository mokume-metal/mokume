<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`MOKUME_WORK_DIR` で区画の基準を与えた環境で、`mokume run` と `mokume doctor` が見張り (`mokume watch`) と同じ区画を見るようになった。

これまではどちらもスケッチの場所しか見ておらず、`run` は見張りが置いた絵の区画に気付かないまま「窓は出ない」と名乗らずに起動し (つまり**黙って何も出ない**)、`doctor` は最後の作り直しを常に「まだ無い」と読んでいた。切り分けの口自身が、切り分けたい「区画の割れ」を再現していたことになる。あわせて `run` の名乗りは区画の在処をそのまま出すようにした — 基準は環境変数が動かせるので、`.mokume/viewport` とだけ言うとスケッチの場所を探して「無い」と読まれる。
