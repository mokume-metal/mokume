<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

読み出した画素 (`PixelBuffer`) と、`Sendable` な公開の値の型 (`Camera`・`Placement`・`Surroundings`・`Transform`・`Orbit`・`SketchSettings`・`Font`・`Model`・`InputEvent`・`Clock`・`Upscale`・`ShaderValue`・`Emitter`・`Force`・`Heading`) を、外のパッケージが main actor の外 (`Task.detached` など) で作り・読み・比べられるようになった ([#4098](https://github.com/mokume-metal/mokume/issues/4098))。

これまでは値を main の外へ渡せても、渡した先で `width` や `==` を使うと組めなかった。`Image.readPixels()` で読んだ画素を解析の仕事へ渡して読む書き方が、そのまま書ける。main から使う既存のコードは変わらない。
