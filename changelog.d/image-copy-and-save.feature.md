<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Image.copy()` で絵を写して取っておけるようになり、`Image.save(_:)` で絵を PNG ファイルにできるようになった。毎フレーム同じ 1 枚に上書きされるカメラの `image` も、キーを押した時点の絵を `copy()` で撮って並べ、`try? shot.save("out/shot-1.png")` でファイルに残せる。

`copy()` は元と画素も面も共有しないので、写した後でどちらを書き換えても他方は変わらない。`save(_:)` は呼んだその場で書き (スケッチの `save(_:)` はフレームの外で書く)、行き先の探し方と出力の変換はスケッチの `save(_:)` と同じで、透けた画素は透けたまま残る。書けない行き先では、行き先と事情を名乗る `ImageFailure.unwritable(path:reason:)` を投げる。`ImageFailure` に case が 1 つ増えたので、`switch` で全 case を数えている場合は `.unwritable` を足す。
