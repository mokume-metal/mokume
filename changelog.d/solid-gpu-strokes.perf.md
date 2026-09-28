<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->
組み込み立体の不透明な既定の線を GPU で広げ、同じ形の塗りの頂点も共有するようにしました。線付きの球などを多数置くときの CPU の計算と GPU への転送量を減らします。描画順と線の太さは保ちます。
