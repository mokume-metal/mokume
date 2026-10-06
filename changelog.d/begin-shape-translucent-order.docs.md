<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape` の説明に、**半透明の閉じた立体は、頂点を積んだ順で奥の面の出方が変わる**ことを書きました。振る舞いは変わっていません。立体は奥行きを書くので、先に積んだ手前の面があると、後から積んだ奥の面は描かれません。同じ頂点の並びでも、形の前に `rotateY(Float.pi)` を足して奥と手前を入れ替えると、透け方が変わります。

**奥の面を先に積むのは、書く側の仕事です。** 組み込みの形 (`box`・`sphere` など) は形の中で奥の面から描かれるので向きで変わりませんが、`beginShape` で並べた頂点は並べ替えません。回して見せる半透明の立体を `beginShape` で組むときは、向きに合わせて積む順を決めてください ([#1939](https://github.com/mokume-metal/mokume/issues/1939))。
