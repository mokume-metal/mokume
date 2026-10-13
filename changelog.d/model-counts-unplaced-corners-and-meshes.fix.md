<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadModel` が、OBJ の面の角に 4 つ目以降の欄がある (`f 1/1/1/1 2 3`) ものと、向きの行に 4 つ目以降の数がある (`vn 1 2 3 4`) ものを、黙って受け取って `Model.skippedLines` に数えていなかったのを直した。どちらも読めない行として数える (面の角は面の行ごと読み飛ばす)。正しい角 (`1`・`1/2`・`1//3`・`1/2/3`)・`vn i j k`・仕様にある `v` の 4 つ目と `vt` の 3 つ目は変わらない。STL では、Model I/O が返した形のうち写せなかった要素 (位置や submesh を持たない mesh・三角形でない submesh・3 つに満たない余りの番号) も数えるようにした (実ファイルの STL では起きない防御で、見える結果は変わらない)。
