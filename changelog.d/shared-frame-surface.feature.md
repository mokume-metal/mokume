<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチが、画面の出口を**プロセスの外へ置ける**ようになった。区画 `.mokume/viewport` を作ってから起動すると、窓を開かずに、焼いた絵を別のプロセスから読める面 (`IOSurface`) へ差し出す。面の番号は `.mokume/viewport/surface.json` に置かれる。

運ぶのは出力段を通した後の絵で、形式は作業空間と同じ半精度のまま — 8 bit へ落とさないので、表示できる範囲を超えた明るさがそのまま届く。面はキャンバスと同じ大きさなので、帯 (レターボックス) は焼き込まれない。

区画が無ければいままでどおり窓を開く。`mokume run` と、直接起動と、束ねた `.app` の振る舞いは変わらない。
