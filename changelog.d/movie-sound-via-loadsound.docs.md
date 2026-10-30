<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Movie` の説明文に、動画の音を鳴らす道を書きました。** `Movie` は音を鳴らさないので、同じファイルを `loadSound` で開いて鳴らし、`jump(_:)` で映像の位置へ合わせます (`loadSound` は `.mov`・`.mp4` の音声トラックを読めます)。合わせ直しは `jump(clip.time + deltaTime)` (`jump` は次のフレームの頭で効く)、止めるときは映像と音の両方、固定の時計で書き出すときは `setup()` で両方を `play()` すれば頭が揃います (`draw()` で同じフレームに呼ぶと音が 1 フレーム早い)。音声トラックの無い動画を `loadSound` で読んだときの失敗の文面も、動画の場合を添えるようにしました。`speed(_:)` を 1 以外にした映像に音を合わせる口はまだありません。
