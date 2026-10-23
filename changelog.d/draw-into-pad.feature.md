<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`draw(into: pg) { … }` で、閉包の中の描く呼び出しが描き場所へ向くようになりました。** 本体向けに書いた `brush()` のような関数を、`pg.` を付けて書き直さずに、そのまま描き場所へ描かせられます (`draw(into: trail) { brush() }`)。閉包を抜けると描く先は本体へ戻り、入れ子にもできます。`width` / `height` は描き場所の大きさを返し、`mouseX` などの入力は本体の窓のままです。

フレームは `pg.draw { }` と同じ規則で開きます。ただし描き切りの失敗は投げず、警告で知らせます。`Canvas` の `force` も、`Sketch` と同じ可変長の形 (`pg.force(dust, .gravity(0, 90), .drag(0.6))`) で書けるようになりました。

揺らぎの種と細かさ・時刻・粒の刻みは、向き先が `Canvas(target:gpu:)` で直に作った面でも、閉包の間はスケッチのものを読み書きします。本体の面を渡したときは、フレームを開き直さず向き先だけを立てます。
