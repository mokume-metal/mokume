<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ウィンドウを持って走るスケッチが、別のアプリから見つけられるよう自分を目録に載せるようになりました。作品のコードにも起動の仕方にも何も足す必要はありません。`mokume run`・束ねた `.app`・直に走らせた作品はライブラリが、`mokume watch` では道具が、`~/Library/Application Support/mokume/frames/` に 1 件ずつ載せ、終わると下ろします。`watch` で保存して作品が入れ替わっても、載せた項目は変わりません。`render` と `SketchView` に埋め込んだ作品は載りません。名乗れない環境 (App Sandbox を付けた `.app` など) では載せずに走り続け、その旨を 1 行だけ出します。この段階では載せるだけで、絵を受け渡す口は後続の版で入ります ([ADR-0049](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md))。
