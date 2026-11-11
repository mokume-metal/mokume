<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`norm`・`map`・`lerp` と `Vector2` / `Vector3` の `interpolated(to:amount:)` (`lerpAngle` も) が、外挿の値が `Float` に収まるのに、途中の引き算や掛け算があふれて ±∞ を返すことがなくなりました。`m` を `Float.greatestFiniteMagnitude` として、`norm(m, -m, 0)` と `map(m, -m, 0, 0, 1)` は ∞ ではなく 2 を、`lerp(m, 0, 2)` は -∞ ではなく `-m` を返します。結果そのものが `Float` に収まらない外挿は、これまでどおり ±∞ を返します。途中があふれない入力の値は、1 ビットも変わりません。
