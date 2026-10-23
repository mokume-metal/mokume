<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch --keep-time` を足した。Swift を保存して作り直しても、新しい版の `time` が 0 へ戻らず、前の版が描いていた秒の続きから出る。`pauseTime()` で止めていれば、止めた秒のまま出る ([#2414](https://github.com/mokume-metal/mokume/issues/2414))。12 秒で一巡する作品の 8 秒目で止めたまま、色を書き換えて保存して詰められる。`.metal` の保存が時刻を残すのと揃う。

- 運ぶのは**作者の時計の秒と、止めているか**の 2 つだけ。`frameCount`・乱数の列・`deltaTime` で積んだ状態 (`Countdown` を含む)・作者の変数は運ばない
- フレームの時計 (`SketchSettings` の `clock` を `.frames` にした作品) でも同じ。`time` は引き継いだ秒から `1/fps` ずつ進み、`frameCount` は 1 から数え直す
- `setup()` で呼んだ `jumpTime(_:)`・`pauseTime()`・`playTime()` は、前の版が止めていても回っていても引き継ぎに勝つ。`setup()` の中で読む `time` も前の版の続きになる
- `setup()` が時計に触れなければ、最初の枚を出す時点の前の版の秒で始める (ビルドと起動の間に前の版で止めた・飛んだ分も届く)。前の版が落ちて居なければ、居なかった間は進めず、最後に書いた秒から始める
- 時計を書くのは、止めた・飛んだなど必要なときと 0.5 秒おきだけで、main の外で書く。書けない・読めないときは、原因と次にすることを 1 度だけ言う
- 旗の無い `watch`・`run`・`render` は変わらず 0 秒から始まる。`mokume render` で書き出した絵は変わらない
