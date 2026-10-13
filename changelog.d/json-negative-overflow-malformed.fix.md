<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadJSONObject` と `requestJSONObject` が、`Double` に収まらない負の数 (`-1e400`・`-1.8e308`) を投げずに読み、`getFloat` が負の無限大を返していたのを直しました ([#2329](https://github.com/mokume-metal/mokume/issues/2329))。正の側 (`1e400`) と同じく、読めない数として `DataFailure.malformed` で投げ、その数が書かれた行を名乗ります。配列や入れ子の中の数も、重複したキーの後ろの値も、URL から読んだ本文も同じです。`Double` に収まる数 (最小値の `-1.7976931348623157e308` まで) はこれまでどおり読めます。

理由の文面も符号によらず揃えました。これまで正の側は `Number wound up as NaN (column 6)` でしたが、どちらも `"weather.json" is broken at line 2: Number -1e400 does not fit in a Double (column 6)` の形で、収まらない数の綴りを名乗ります。収まらない数がいくつもあれば、文字の中で最初のものを名乗ります。
