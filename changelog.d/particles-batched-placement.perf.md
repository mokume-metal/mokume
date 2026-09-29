<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`emit` で粒を出す処理が軽くなりました。粒を 1 つ置くたびに状態の並びへ書いて記帳していたのを、続いた枠ごとにまとめて書くようにしたためです。1 フレームに 2 万粒を出すと、`emit` が約 3.6 ms から 1.2 ms になります。出る粒の位置・速さ・寿命・色と、その後の `random()` の値は変わりません。
