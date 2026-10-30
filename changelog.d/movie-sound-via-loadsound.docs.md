<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Movie` の説明文に、動画の音を鳴らす道を書きました。** `Movie` は音を鳴らさないので、同じファイルを `loadSound` で開いて鳴らし、`jump(_:)` で映像の位置へ合わせます (`loadSound` は `.mov`・`.mp4` の音声トラックを読めます)。固定の時計で書き出すときは、同じフレームで `clip.play()` と `song.play()` を呼ぶと音の頭が映像より 1 フレーム早いので、音の `play()` を 1 フレーム遅らせると揃います。`speed(_:)` を 1 以外にした映像に音を合わせる口はまだありません。
