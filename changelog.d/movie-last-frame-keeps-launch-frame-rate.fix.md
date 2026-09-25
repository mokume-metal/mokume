<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`var settings` と持って走っている最中に `settings.frameRate` へ代入したスケッチで動画を撮ると、最後の 1 枚だけが代入した値の長さになっていたのを直しました。** 各枚の間隔は起動のときの `frameRate` で刻まれるのに、最後の 1 枚の長さだけは最初に `save` か `beginRecord` を呼んだときの値を読んでいたため、たとえば 60 で起動して 5 を代入してから撮ると、最後の 1 枚が 1/60 秒ではなく 1/5 秒映っていました。いまは最後の 1 枚も、各枚の間隔と同じ起動のときの `frameRate` の 1 フレームぶんです。走っている最中の代入は、これまでどおり画面の刻みにも `time` / `deltaTime` にも効きません。
