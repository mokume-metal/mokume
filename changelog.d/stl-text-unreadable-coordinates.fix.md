<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

文字の STL で座標が読めない面を、0 や別の数にして描かず、面ごと読み飛ばして `Model.skippedLines` に数えるようになった。たとえば `vertex 0x10 0.0 0.0` (16 進)・`vertex nan 0 0`・`vertex a b c`・数が 2 つの `vertex 1 2` を持つ面は、これまで原点へ潰れた三角形 (`0x10` は x が 16 の三角形) として描かれていたが、いまはその面だけが消え、`skippedLines` が面の数だけ増える (読み込んだときの診断にも出る)。OBJ の読めない行・バイナリの STL の座標が数でない面と同じ扱い。`vertex` の欄がちょうど 3 つの有限な 10 進の数 (`1.5`・`-2`・`3e1`) の面は、これまでと同じ位置で読む。`facet normal` の欄が読めない面は残し、向きは書いていないのと同じ (形から求めた両面) になる。
