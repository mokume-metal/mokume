<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ノイズの `play`・`set` とオシレータの `set` で引数を 1 つ省いた形、ディレイの 3 引数の `process` が、Processing Sound と同じ並びで読まれるようになりました ([#3719](https://github.com/mokume-metal/mokume/issues/3719))。手本から写した `noise.play(0.5, -1)` は、これまで振幅に -1 を足した中央の音になっていましたが、これからは手本どおり左へ寄せた音になります。

| 呼び方 | これまで | これから |
| --- | --- | --- |
| `noise.play(amp, x)`・`noise.set(amp, x)` | `x` はオフセット (`add`) | `x` は定位 (`pos`) |
| `osc.set(freq, amp, x)` | `x` はオフセット (`add`) | `x` は定位 (`pos`) |
| `delay.process(input, maxDelayTime, x)` | `x` は戻す割合 (`feedback`) | `x` は始めの遅れ (秒。`delay.time(x)` と同じ) |

`noise.play(amp)`・`noise.play(amp, add, pos)`・`osc.set(freq, amp)`・`osc.set(freq, amp, add, pos)`・`delay.process(input, maxDelayTime)` の意味は変わりません。引数を省いた形は、これまでどおり省いたオフセット・定位を 0 (中央) に戻します。

移行: 2 番目の引数にオフセットを渡していた `noise.play(amp, add)`・`noise.set(amp, add)` は、定位の 0 を足して `noise.play(amp, add, 0)` と書いてください。`osc.set(freq, amp, add)` は `osc.set(freq, amp, add, 0)` です。`delay.process(input, maxDelayTime, feedback)` は、`delay.process(input, maxDelayTime)` の後に `delay.feedback(feedback)` を呼んでください。どれもコンパイルは通ったまま音だけが変わるので、書き換えが要る呼び出しはコンパイラが教えてくれません。
