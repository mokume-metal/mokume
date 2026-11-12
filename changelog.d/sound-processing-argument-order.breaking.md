<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ノイズ・オシレータの `play`・`set` とディレイの `process` が、引数を省いた形も Processing Sound と同じに読まれるようになりました ([#3719](https://github.com/mokume-metal/mokume/issues/3719))。手本から写した `noise.play(0.5, -1)` は、これまで振幅に -1 を足した中央の音になっていましたが、これからは手本どおり左へ寄せた音になります。省いた値も手本と同じく今のまま保たれ、`noise.pan(-1)` の後の `noise.play(0.5)` は左のまま鳴ります (これまでは中央に戻っていました)。

どれもコンパイルは通ったまま音だけが変わるので、書き換えが要る呼び出しをコンパイラは教えてくれません。

| 呼び方 | これまで | これから | これまでと同じ音にする書き方 |
| --- | --- | --- | --- |
| `noise.play(amp, x)`・`noise.play(amp, x, at: t)`・`noise.set(amp, x)` | `x` はオフセット (`add`)。定位は 0 に戻る | `x` は定位 (`pos`)。オフセットは今のまま | `noise.play(amp, x, 0)`・`noise.play(amp, x, 0, at: t)`・`noise.set(amp, x, 0)` |
| `osc.set(freq, amp, x)` | `x` はオフセット。定位は 0 に戻る | `x` は定位。オフセットは今のまま | `osc.set(freq, amp, x, 0)` |
| `delay.process(input, maxDelayTime, x)` | `x` は戻す割合 (`feedback`) | `x` は始めの遅れ (秒。`delay.time(x)` と同じ) | `delay.process(input, maxDelayTime)` の後に `delay.time(0.25)`・`delay.feedback(x)` |
| `delay.process(input, maxDelayTime)` | 上限だけを決め、遅れは今のまま (既定 0.25 秒) | 遅れも上限と同じ値になる (前に決めた遅れは上書き) | `delay.process(input, maxDelayTime, 0.25)` (または前に決めた遅れを 3 つ目に渡す) |
| `noise.play(amp)`・`noise.play(amp, at: t)`・`noise.set(amp)` | オフセット・定位を 0 に戻す | オフセット・定位は今のまま | `noise.play(amp, 0, 0)`・`noise.play(amp, 0, 0, at: t)`・`noise.set(amp, 0, 0)` |
| `osc.play(freq, amp)`・`osc.play(freq, amp, at: t)`・`osc.set(freq, amp)` | オフセット・定位を 0 に戻す | オフセット・定位は今のまま | `osc.play(freq, amp, 0, 0)`・`osc.play(freq, amp, 0, 0, at: t)`・`osc.set(freq, amp, 0, 0)` |
| `osc.play(freq, amp, add)`・`osc.play(freq, amp, add, at: t)` | 定位を 0 に戻す | 定位は今のまま | `osc.play(freq, amp, add, 0)`・`osc.play(freq, amp, add, 0, at: t)` |

意味の変わらない形: 全部の値を渡す `noise.play(amp, add, pos)`・`noise.set(amp, add, pos)`・`osc.play(freq, amp, add, pos)`・`osc.set(freq, amp, add, pos)` (と `at:` つき)、引数なしの `play()`・`play(at:)`。オフセット・定位を一度も変えていない音 (作った直後の既定のまま) は、省いた形でもこれまでと同じ音です。

`osc.set(freq, amp, x)` の `x` は定位ですが、`osc.play(freq, amp, x)` の `x` はオフセットです。同じ 3 引数で意味が違うのは Processing Sound と同じです。

移行: オフセットや定位を `pan(_:)`・`add(_:)` で変えた後に、省いた形で「中央・オフセット 0 に戻す」つもりで呼んでいたコードは、上の表の右端の書き方で 0 を渡してください。
