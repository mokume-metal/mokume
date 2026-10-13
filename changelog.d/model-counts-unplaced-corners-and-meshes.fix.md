<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadModel` が、OBJ の面の角に 4 つ目以降の欄がある (`f 1/1/1/1 2 3`) ものと、STL で面にならなかった要素 (位置を持たない mesh・三角形でない submesh・3 つに満たない余りの番号) を、黙って受け取り捨てて `Model.skippedLines` に数えていなかったのを直した。OBJ の角は面の行ごと読み飛ばして 1 数え、STL は要素ごとに数える。正しい角 (`1`・`1/2`・`1//3`・`1/2/3`) と正しい三角形は変わらない。
