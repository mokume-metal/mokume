<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**道を足し引きできるようになりました。** `Path.union([a, b])` は重なる所の輪郭を消して 1 本の輪郭にし、`a.subtracting(b)` は `b` の内側を抜き、`a.intersection(b)` は重なりだけを残します。重ねた円の和を `noFill()` と `stroke(…)` で描いても、重なりの内側に線が残りません。内側は `contains(_:)` と同じ回り数の規則で決まり、輪の穴は穴のままで、向きの逆な道どうしでも重なりが抜けません。結果は CoreGraphics が計算するので、同じ機械・同じ OS の版なら点が一致し、OS の更新で動くことがあります。
