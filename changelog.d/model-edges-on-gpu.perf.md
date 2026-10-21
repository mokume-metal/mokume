<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

読み込んだモデルを既定の線 (不透明・miter) で置くと、線を GPU で広げるようになり、2 枚目以降のフレームが軽くなった。10 万三角形の波打つ面で 2 枚目が約 50 ms から約 5 ms になる (release・Apple M3 Max)。絵は変わらない。

開いた端を持つ・同じ直線に載る 2 辺が集まる点を持つ・骨が大きすぎる (線の骨だけで 64 MiB を超える。50 万三角形級) モデルと、半透明・丸い折れ目・利用者のシェーダ・貼る絵のある線は、これまでどおり CPU で組む。
