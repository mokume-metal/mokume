<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

粒の引く力・押す力 (`.attract` / `.repel`) に、弱まり始める距離 `weakeningBeyond` を渡せるようにした。渡すと、その距離より遠い粒では力が距離に反比例して弱まる (内側はこれまでどおり `strength` のまま)。これまでの引く力は距離に依らないので、渦 (`.swirl`) と抵抗 (`.drag`) を組んで撒き切った粒を長く回すと、全粒が 1 本の細い輪へ集まって広がりが消えていた。`weakeningBeyond` を渡して `strength × weakeningBeyond` を回る速さの 2 乗に合わせると、その外のどの半径でもおおよそ釣り合い、撒いた広がりが残る。回る速さは `渦 ÷ 抵抗` より少し遅い (60 fps・抵抗 1.2 で 1%)。詳しくは `Force` の説明の「渦と抵抗を組むと」にある。

省けばこれまでと同じ力で、絵は 1 画素も変わらない。0 以下・数でない値・無限を渡すと、注意を 1 度言って弱まらない力として効かせる。

**移行**: `.attract` に値が 1 つ増えたので、`case .attract(let x, let y, let z, let strength)` のように**値を取り出して分解しているコードは組めなくなる**。末尾に 1 つ足して `case .attract(let x, let y, let z, let strength, _)` と書き直す。`.attract(x, y, strength: 40)` や `.repel(x, y, strength: 40)` のように力を作るだけのコードは、そのまま動く。
