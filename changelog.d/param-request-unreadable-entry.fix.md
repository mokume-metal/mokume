<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

つまみの面 (`.mokume/params/request.json`) へ書く値のうち 1 件が読めなくても、要求ごと応答なしに捨てられなくなった。これまでは `Double` に収まらない数 (`1e400`)・知らない `type`・型に合わない値 (`float` に文字列、`int` に `3.5`、`vec2` に 3 成分) の 1 件で、同じ要求の他の値も入らず、書いた側には何も返らなかった ([#2496](https://github.com/mokume-metal/mokume/issues/2496))。

いまは読めない 1 件だけが応答の `rejected` に載り、他の値は当たる。数が `Double` に収まらないときは `notFinite`、形が違うときは `typeMismatch` で、名前を読めない 1 件は名前を空にして `typeMismatch` に載る。応答の形と `schemaVersion` は変わらない。要求の `id` が読めない・JSON として壊れている要求は、echo する相手が無いので、これまでどおり応答しない。
