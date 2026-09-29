<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`noiseSeed(_:)` / `noiseDetail(_:_:)` で決めた揺らぎの種と細かさが、描き場所 (`createGraphics`) の断片に届いていなかったのを直しました。描き場所で塗った断片の `mokume_noise` / `mokume_noiseGradient` は作った時点の既定の設定を読み続け、画面の `noise()` とは別の模様を出していました。種と細かさはスケッチに 1 つになり、描き場所 (と描き場所から作った描き場所) も画面と同じものを読みます。**描き場所の上で `pg.noiseSeed(_:)` / `pg.noiseDetail(_:_:)` を呼ぶと、画面の揺らぎも同じ値に変わるようになりました** (これまでは描き場所だけに効いていました)。同じ種から別の模様が欲しいときは、引く座標をずらしてください。
