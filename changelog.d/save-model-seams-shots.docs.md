<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

モデルを読んで置く口 (`loadModel(_:normalize:)` と `model(_:)`)、連番を撮る口 (`beginRecord(_:)`)、走っているスケッチへ差込口を足す・外す口 (`attach(_:)` と `detach(_:)` の入り口と出口) に、例と絵が付きました。

`loadModel` は、大きさだけ 30 倍違う角錐の OBJ 2 つを、既定の整え方で読むと同じ大きさで頂点が上を向き、`normalize: false` で読むとファイルの座標のまま (小さいほうは点になり、頂点は下を向く) になることを並べています。OBJ は文字のファイルなので、例はその場で書き出してから読んでいます。`model` は同じ角錐を、塗りだけ・塗りと線・線だけで置き、線が稜線だけを通って底の四角を割った対角線には出ないことを見せています。

`beginRecord` は、撮った連番を `endRecord()` の直後に読み戻して並べ、入るのが呼んだフレームから `endRecord()` の前のフレームまでであることを動く絵で見せています。`attach` と `detach` は、呼ばれた回数を数える入り口と、受け取ったフレームの番号を控える出口で、足したフレーム・外したフレームを境に数がどう変わるかを動く絵にしました。

`save(_:)` は画面の絵を変えずにファイルを書く口なので、絵は付いていません。`requestModel(_:normalize:)` は `loadModel` の絵、`endRecord()` は `beginRecord` の絵を見てください。
