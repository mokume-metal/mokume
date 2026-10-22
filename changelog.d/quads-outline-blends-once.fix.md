<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape(.quads)` の凹んだ 4 点を半透明の線で描くと、向かい合う辺の重なりを 2 回混ぜて濃くなっていたのを直しました。同じ 4 点を `quad()` で描くと 1 回だけ混ざるので、描き方によって線の濃さが違っていました。いまは `.quads` の 4 点も `quad()` と同じ規則で、辺が交わらなければ線全体を 1 回だけ、向かい合う辺が交わる (砂時計の) 4 点は交点で 2 回混ぜます。1 つの `beginShape(.quads)` に並べた四角どうしは別々の輪郭なので、重なれば 2 回混ざります。`beginShape(.polygon)` は変わりません。
