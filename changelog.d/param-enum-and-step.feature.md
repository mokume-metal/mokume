<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`@Param` に Swift の enum をそのまま宣言できるようになり、実数のスライダーの刻みを `step:` で書けるようになった。`enum Palette: String, CaseIterable { case ember, tide, moss }` を `@Param var palette: Palette = .ember` と書くと、窓に ember / tide / moss の候補が出て、選ぶと値が変わる — **型の側には何も書き足さない**。`switch` が網羅されるので、これまで `choices: ["circle", "square"]` の文字列で通っていた綴り間違いが、組む時点で止まる。

面に出る型は `string` のままで、外から `{"name":"palette","type":"string","value":"tide"}` と書くと当たり、case に無い `"sea"` は文字の候補と同じく候補の外として断られる。保存した case を消す・名前を変えると、その保存は候補の外として捨てて名乗り、コードの既定値の case が効く (case を足しただけなら、保存はそのまま戻る)。

`@Param(0...1, step: 0.05) var density: Double = 0.4` は、窓のスライダーが 0.05 ずつ動く (0.4 の次は 0.45)。**刻みはスライダーの動き方だけ**を決める — 外から書いた `0.37` ・保存からの復元・コードからの代入は刻みへ丸めず、応答の `clamped` も「範囲へ収めた」の意味のままである。刻みはつまみの目録 (`params` の応答) の `step` にも載る。整数のスライダーは 1 刻みのままで、0 以下・非有限の刻みは置かずに 1 度だけ知らせる。
