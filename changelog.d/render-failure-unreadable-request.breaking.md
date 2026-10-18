<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume render` が渡す書き出しの頼み (環境変数 `MOKUME_RENDER`) をスケッチが読めない・書き出せないとき、スケッチは窓を開いて 0 で終わらず、新しい `RenderFailure.unreadableRenderRequest(value:)` を投げて起動を断るようにしました ([#2481](https://github.com/mokume-metal/mokume/issues/2481))。`@main` のスケッチは何もせずに、窓を開かず理由を標準エラーに出して 1 で終わります。

これまでは、読めない値を窓の経路へ倒していたため、`mokume render` は何も書かれていないのに書けたと読んでいました。値が無いスケッチ (ふだんの `run` など) は、これまでどおり窓で走ります。

移行: `SketchApplication(sketch:gpu:)` を自分で呼んで `RenderFailure` を `switch` で網羅している場合は、コンパイル時に `unreadableRenderRequest` の枝が足りないと指摘されます。枝を足してください (文面は `\(failure)` で人向けに出せます)。環境に `MOKUME_RENDER` を手で置いていて、窓で走らせたいスケッチは、その変数を外してください。
