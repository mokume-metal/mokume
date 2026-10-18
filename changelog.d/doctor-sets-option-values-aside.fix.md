<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume doctor -c release` が、`release` という場所を診なくなった。これまでは `doctor` が `-c` を知らない綴りとして脇へ置くだけで、続く `release` を場所として取り、在らない `./release` を診たと名乗っていた ([#2484](https://github.com/mokume-metal/mokume/issues/2484))。`doctor` は、どの口の値を取る選択肢 (`-c`・`--configuration`・`--scratch-path`・`render` の `--fps`・`--seconds`・`--out`・`bundle` の `--out`・`new` の `--path`・`--local`) も、値ごと脇へ置いて走らせた場所 (または渡した場所) を診る。脇へ置いたものは `Ignored arguments doctor does not take: -c release` と名乗り、値が無ければ `-c (no value)` と言う (止まらない)。次の語が `-` で始まる、または `-c` の値が `debug`・`release` でないときは値に取らないので、`doctor -c /path/to/sketch` は渡した場所を診る。

`run --configuration=release` のように `=` で値をつなぐ綴りは、これまでどおり受け付けない。ただし `Unknown option` ではなく、`--configuration release` と空白で区切るよう案内する (`run`・`watch`・`render`・`bundle`・`new` の、宣言済みの綴りすべて。空白を含む値は引用符で包んで示す)。`--nope=1` のような宣言されていない綴りは、いままでどおり `Unknown option` のまま。
