<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

OS が GPU と共有する面 (`IOSurface`) を、CPU で画素を作り直さずに `Image` へ書ける `Image.write(PixelSurface)` を足した。`PixelSurface` は BGRA の 8 bit の面と、その色を Display P3 の 8 bit へ写す表 (`PixelSurface.ColorTable`) を持ち、色の変換は表を GPU で引いて行う。結果は、同じ表で作った `DisplayImage` を書いたときと 1 bit も違わない。表は作り手が自分の色の変換を青の値ごとの 256 枚の絵に通して作る (数十 ms かかるので、色の意味が決まったときに 1 度作って使い回す)。外のパッケージ (別のアプリから面を受け取る道など) も同じ口で書ける。mokume のカメラと動画をこの道に乗せるのは続く変更で行う ([#2962](https://github.com/mokume-metal/mokume/issues/2962))。
