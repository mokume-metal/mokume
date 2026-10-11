<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`@Param` に非有限の数 (`.nan`・無限) を書くと、そのまま載ってしまい、保存 (`.mokume/state/params.json`) とつまみの応答が、他の値も含めてまるごと書けなくなって、窓のつまみが動かなくなったので、受け取らないようにしました。`radius = .nan` や `radius += .infinity` と書いても値は前のまま動かず、標準エラーに 1 度だけ知らせます (例: `The knob "radius" was given nan, which is not a finite number, so it stays at 10.0 (said once for this knob)`)。そのため、書いた直後に `radius` を読むと、書いた値ではなく前の値が返ります。組と色は、成分のどれか 1 つでも非有限なら値ごと受け取りません。範囲の外でも、有限の値はこれまでどおり締めずに受け取ります。

範囲を宣言していない `Float` へ外から `{"type":"float","value":1e300}` を書いたときも、`Float` では無限になるので、載せずに応答の `rejected` に理由 `notFinite` で載せます (保存からの復元では `discarded`)。`schemaVersion` は 2 のままです。

観測の `expose(_:_:)` も同じで、`expose("r", Float.nan)` のように非有限の値を差し出すと、その値は差し出さず、標準エラーに 1 度だけ知らせます。以前は応答がまるごと置けなくなりましたが、いまは他の値を載せて置かれます。
