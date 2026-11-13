<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Path.clipped(to:)` で、道を線とみなし、別の道の内側にある部分だけを残せるようになった。ペンプロッタ風の斜線を `createPath { }` で並べ、`shape(hatch.clipped(to: cloud))` と描けば、斜線が形の中だけに引かれる。切った片は開いた部分道で、端点は形の縁の上に乗り、元の向きを保つ。全部が内側にある閉じた部分道は閉じたまま残る。

結果は線として描く (`noFill()` を指定してから `shape(_:)`)。塗りを指定したままだと、片が細い欠片として塗られうる。
