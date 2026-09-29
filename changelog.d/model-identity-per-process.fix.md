<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

本体と描き場所 (`createGraphics`) で別々に `loadModel` したモデルを同じ描き場所に置くと、片方のモデルがもう片方の形 (塗り・稜線・影) で描かれることがあったのを直しました。読み込んだモデルの見分けに使う番号が描き場所ごとに 1 から振られていて、違うモデルが同じ番号を持っていたためです。別々の描き場所で読んだモデルどうしを `==` で比べると `true` になっていたのも、`false` になります。
