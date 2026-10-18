<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume doctor -c release` が、`release` という場所を診なくなった。これまでは `doctor` が `-c` を知らない綴りとして脇へ置くだけで、続く `release` を場所として取り、在らない `./release` を診たと名乗っていた ([#2484](https://github.com/mokume-metal/mokume/issues/2484))。`doctor` も `-c`・`--configuration`・`--scratch-path` を値を取る選択肢として知り、値ごと脇へ置いて走らせた場所 (または渡した場所) を診る。脇へ置いたものは `Ignored arguments doctor does not take: -c release` と名乗る (値が無い `doctor -c` でも止まらない)。

`run --configuration=release` のように `=` で値をつなぐ綴りは、これまでどおり受け付けない。ただし `Unknown option` ではなく、`--configuration release` と空白で区切るよう案内する (`run`・`watch`・`render`・`bundle`・`new` の、宣言済みの綴りすべて)。`--nope=1` のような宣言されていない綴りは、いままでどおり `Unknown option` のまま。
