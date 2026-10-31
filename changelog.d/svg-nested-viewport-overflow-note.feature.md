<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape` が、入れ子の `<svg>` の表示枠の外に描くものがあるとき、切り抜かずに描くことを 1 度知らせるようになった。

SVG は入れ子の `<svg>` を表示枠で切り抜く (`overflow` の既定は `hidden`) が、mokume は切り抜かずに枠の外まで描く。これまでは黙って描いていたので、ブラウザと違う絵になっても気付けなかった。いまは、描くものが表示枠をはみ出すと、そのファイルにつき 1 度、切り抜かないことと入れ子の `<svg>` の行を知らせる。描く絵は変わらない。`overflow` が `visible` か `auto` の入れ子、中身が枠に収まる入れ子、根の `<svg>` は知らせない。
