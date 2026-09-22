<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

GPU が積んだ仕事を打ち切った (page fault・hang など) 後に完了の待ちが期限を越えると、「One frame is drawing too much」と、描きすぎのせいだと言い切る文面が出ていました。本当の原因は打ち切りの側なので、この文面を読むと形や光を減らす方向へ切り分けてしまいます ([#1343](https://github.com/mokume-metal/mokume/issues/1343))。

直近に結末が届いた投入が打ち切りだったときは、`RenderFailure.timedOut(seconds:)` の代わりに新しい `RenderFailure.workDropped(reason:)` を投げるようにしました。文面の 1 行目で、Metal が名乗った打ち切りの理由を出します。打ち切りの後に正常に終わった投入があれば回復したとみなし、以後の期限切れは今までどおり `.timedOut` です。

移行: `RenderFailure` を `switch` で網羅している場合は、コンパイル時に `workDropped` の枝が足りないと指摘されます。枝を足してください。`.timedOut` を名指しで受けて待ちの期限切れを扱っているコードは、打ち切りの後では `.workDropped` が届くようになるので、同じ扱いにするなら両方を受けてください。
