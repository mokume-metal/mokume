<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`requestModel` で大きなモデルを読んでいる間も、描画が止まらなくなりました。ファイルを読んだ後の、置ける形へ整える仕事 (全頂点の走査) を描画と同じ main で行っていたためで、50 万三角形の OBJ では main が約 30 ms 止まっていました。いまは約 1.6 ms (計測の刻みの下限) です (Apple M3 Max、release)。届くモデルと読み込み全体にかかる時間は変わりません。初めて置いたフレームで GPU へ送る費用も、これまでどおりかかります。
