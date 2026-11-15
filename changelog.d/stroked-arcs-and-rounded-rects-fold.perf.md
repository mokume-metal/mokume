<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` や `texture()` を効かせた間に大量に置く、輪郭つきの角丸の `rect` と輪郭つきの `arc` (`.chord`・`.open`・閉じ方を渡さない既定)、貼る絵つきの `.chord` / `.open` が速くなりました。回転だけ違う輪郭つきの `.chord` を 10,000 個置く場面で、フレームの CPU 時間が 約 430 ms → 約 4 ms です。形が同じ図形を 1 つの雛形にまとめて置くようになったためで、描く絵は変わりません。`.open` と既定の弧の輪郭が描く画素で 1 画素より細いときと、貼る絵と輪郭を両方持つ図形は、これまでどおり置き場所ごとに組みます。
