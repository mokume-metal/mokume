<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`BandPass` に、帯域の細さを Q (中心周波数 ÷ 幅) で決める `res(_:)` を足しました。Processing Sound の `BandPass.res()` に当たり、範囲も同じ 0.1〜10 です。`bw(_:)` が幅を Hz で保つのに対し、`res(_:)` は中心周波数を動かすと幅も比例して変わるので、音の高さに追従する細さを書けます。`bw(_:)` と `res(_:)` は後に呼んだほうが効きます。
