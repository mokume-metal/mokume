<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`loadModel` / `requestModel` が STL (.stl) も読めるようになった。** 3D プリンタ向けに配られている部品を、外の道具で OBJ に変換せずにそのまま置ける。口は増えておらず、拡張子で読み手を選ぶ (大文字小文字は問わない)。文字の STL もバイナリの STL も読み、整え方 (`normalize`) は OBJ と同じに効く。OBJ の読み込みの結果は変わらない。

STL は点を共有しないので、**面ごとに平らに光る** (OBJ で面の向きを書かない形は、隣の面と向きが均される)。STL には縦軸の約束が無く、3D プリンタ向けのものは z を上に書くことが多いので、そのまま置くと寝て見える — 起こすなら `rotateX` で 4 分の 1 回す。文字の STL で数として読めない座標は 0 として読まれる。バイナリの STL で座標が数でない面は読み飛ばし、`Model.skippedLines` に面の数として数える。

読めない STL (壊れている・途中で切れている・空のファイル) は `ModelFailure.unreadable` を投げ、説明は「STL として読めない」と名乗る。面を 1 つも持たない STL は投げずに空のモデルになる (OBJ と同じく、置いたときに警告する)。対応していない形式を渡したときの説明 (`ModelFailure.unsupported`) は、読める形式の一覧 (OBJ と STL) を名乗るようになった。
