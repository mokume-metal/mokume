<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

粒の 4 口 (`makeParticles(count:)` / `emit(_:from:toward:rate:speed:life:size:color:)` / `force(_:_:)` / `particles(_:)`)・`noLoop()`・`currentCamera` に、引数を 1 つずつ動かした例と動く絵を 15 枚付けた。

粒は、枠 (`count`) が足りないと古い粒から上書きされて噴水の柱が短く切れる、混ぜ方は作った瞬間に焼き付き `draw()` で後から加算にしても効かない、毎秒 6 個でも端数を繰り越して 10 枚ごとに 1 個出る、速さ・寿命・大きさ・出る場所・飛ぶ向きを 1 つずつ変えるとどう広がるか、真横から見ると面内に飛んだ粒は 1 本の線に並び `.sphere` は丸く広がる、積んだ力は 1 刻みで使い切られる、同じ群を 2 回呼ぶと 2 倍の速さで進む、板は回しても傾かず倍率だけを受ける — を絵で見られる。`noLoop()` は `setup()` で呼ぶと 1 枚目が続き、`draw()` の中で呼ぶとその枚を描き切って止まることを、`currentCamera` は値で持った 2 つの視点を当て替える使い方を見せている。

`loop()` と `redraw()` は止めた後に入力のコールバックから呼ぶ口で、`assetURL(_:)` は資材ファイルの場所を返す口なので、絵は付いていない。
