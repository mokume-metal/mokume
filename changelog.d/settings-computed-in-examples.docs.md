<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

作例 (参照スケッチ 31 本)・入口の「はじめの 1 本」・`createVideo` の説明文の例の `settings` を、`mokume new` の雛形と同じ計算型 (`var settings: SketchSettings { SketchSettings(…) }`) に揃えた ([#2256](https://github.com/mokume-metal/mokume/issues/2256))。これまでは格納型 (`var settings = SketchSettings(…)`) で書かれていた。格納型は `draw()` の中で `settings.frameRate = 30` のように代入でき、読み返すと代入した値が返るので変えられたように見えるが、実際の速さは変わらない (`SketchSettings.frameRate` の説明文が名指している罠)。計算型なら同じ代入は組み立てで `cannot assign to property: 'settings' is a get-only property` として止まる。

入口の例は `mokume new my-sketch` が実際に作るもの (`import Foundation` を含む) と同じになった。格納型の書き方はこれまでどおり動く (走っている最中の代入には 1 度だけ警告が出る)。
