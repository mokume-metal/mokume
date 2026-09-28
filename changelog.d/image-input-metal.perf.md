<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Image.write` で大きな画像を更新するときの色変換を Metal へ移し、少数の画素編集と合わせて描画時に反映するようにした。書き方や画像の値は変わらず、`get` で読み始めた場合は CPU で扱う。映像などの連続更新で CPU の負荷を減らす一方、GPU が既に混み合っている処理では改善しない場合がある。

未更新の画像を配置した後に `write`・`set`・`fill` した場合も、その描き切りへ反映されるよう修正した。
