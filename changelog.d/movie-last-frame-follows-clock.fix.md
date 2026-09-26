<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`SketchRuntime(sketch:gpu:clock: .frameIndex(frameRate:))` に作品の `settings.frameRate` と違う刻みを渡して動画を撮ると、最後の 1 枚だけが作品の宣言の長さになっていたのを直しました。** 各枚の時刻は渡した時計で刻まれるのに、最後の 1 枚の長さだけは宣言から採っていたため、たとえば宣言 60 の作品を 30 の時計で回すと、最後の 1 枚が 1/30 秒ではなく 1/60 秒映り、動画全体が半コマ短くなっていました。いまはフレーム番号から導く時計なら、最後の 1 枚もその刻みの 1 フレームぶんです。実時間の時計と、時計を渡さない既定の経路は変わりません。
