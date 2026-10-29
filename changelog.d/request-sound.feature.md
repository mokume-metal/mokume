<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音声ファイルを、フレームを止めずに読む `requestSound(_:)` を追加した。`requestImage(_:)` と同じ `async` の口で、走っているスケッチの中で起こした `Task` から呼べる。`selectInput(_:)` で選んだ音声を `Task { guard let path = await selectInput("音声を選ぶ") else { return }; song = try? await requestSound(path) }` の形で、警告を出さずに読んで鳴らせる (これまでは `Task` の中で `loadSound(_:)` が `notRunning` を投げ、次の `draw()` で読むと「`draw()` の中の同期の読み込み」の警告が出た)。`draw()` の中で `loadSound(_:)` を呼んだときの警告も、`requestSound(_:)` へ案内するようになった。`selectInput(_:)` の説明も、`Task` の中で読むなら `requestImage(_:)`・`requestTable(_:header:)`・`requestSound(_:)` などの待つ口へ渡す、と直した。
