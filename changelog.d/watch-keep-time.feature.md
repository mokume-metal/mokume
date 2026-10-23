<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch --keep-time` を足した。Swift を保存して作り直しても、新しい版の `time` が 0 へ戻らず、前の版が描いていた秒の続きから出る。`pauseTime()` で止めていれば、止めた秒のまま出る ([#2414](https://github.com/mokume-metal/mokume/issues/2414))。12 秒で一巡する作品の 8 秒目で止めたまま、色を書き換えて保存して詰められる。`.metal` の保存が時刻を残すのと揃う。

- 運ぶのは**作者の時計の秒と、止めているか**の 2 つだけ。`frameCount`・乱数の列・`deltaTime` で積んだ状態 (`Countdown` を含む)・作者の変数は運ばない
- フレームの時計 (`SketchSettings` の `clock` を `.frames` にした作品) でも同じ。`time` は引き継いだ秒から `1/fps` ずつ進み、`frameCount` は 1 から数え直す
- `setup()` の `jumpTime(_:)` は引き継ぎに勝つ
- 旗の無い `watch`・`run`・`render` は変わらず 0 秒から始まる。`mokume render` で書き出した絵は変わらない
