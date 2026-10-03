<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`RenderTarget.encodeForDisplay(scale:)` と `writePNG(to:)` が速くなりました。これまでは全画素を CPU へ読み戻し、画素ごとに CPU で色を変換していましたが、録画・観測・`save()` と同じ GPU の出力段を通るようになりました。Apple M3 Max の release で、1 回あたり 1920×1080 は約 50 ms から 0.6 ms、3840×2160 は約 199 ms から 1.4 ms、3840×2160 の `scale: 0.25` は約 15 ms から 1.7 ms です。出るバイト列、待ってから返ること、失敗したときに投げる `RenderFailure` は変わりません。
