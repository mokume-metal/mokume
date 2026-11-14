<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

計算が書いた数の並びを、位置と進む向きとして読み、形を進む向きへ回して置けるようになった (`shape(dart, at: agents, layout: .positionAndHeading)`)。並びの 6 つ (位置の x・y・z と進む向きの x・y・z) が 1 か所になり、形の +x 軸を進む向きへ向ける。形の +y 軸は画面の面 (x と y の面) に留まり、進む向きの軸まわりにはひねらない。向きの長さは問わないので、計算が進めた速度をそのまま渡せ、GPU で動かす 2 万匹の群れも読み戻しなしで描ける。長さ 0 の向きは回さずに置き、位置か向きに数でない値・無限を含む 1 か所は置かない。並びの長さが 6 で割り切れないときは、`count / 6` の切り捨ての数だけ置き、端数があることを 1 度だけ警告する ([#3582](https://github.com/mokume-metal/mokume/issues/3582))。

**公開の `Placement.Layout` に場合 `positionAndHeading` を足したので、破壊的な変更である。** **移行**: `Placement.Layout` を網羅して `switch` していたなら、`.positionAndHeading` の場合を足す。`shape(_:at:layout:)` に `.position` を渡す書き方は、そのまま組めて絵も変わらない。
