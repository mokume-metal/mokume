<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`createShape` の中で呼んだ `shader()` と `numbers()` が、組み立てのあとも効いたまま残らなくなりました。** これまでは形の中だけのつもりで掛けた断片や並びが、そのあとに描く図形にも効いていました。形にはこれまでどおり焼き付きます。

**`setup()` で `createShape` や `makeParticles` を呼んでも、身に覚えのない警告が出なくなりました。** 組み立ての中で置いた塗りが外へ残ることも無くなり、`makeParticles` を呼ぶと、その前に置いた塗りが白に変わっていた問題も直りました。`makeParticles(count:)` の説明には、粒の混ぜ方が作った瞬間に決まることを書き足しました。
