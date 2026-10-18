<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Image.save(_:)` の失敗を運ぶために、`ImageFailure` に `unwritable(path:reason:)` の case を足しました ([#2449](https://github.com/mokume-metal/mokume/issues/2449))。行き先の綴りと、書けなかった事情 (置き場が無い・書く権利が無いなど) を名乗ります。`saveTable` などが投げる `DataFailure.unwritable(path:reason:)` と同じ形です。

これまでの口 (`loadImage`・`createImage`・`createVideo` など) は、この case を投げません。**`ImageFailure` を `switch` で全 case 数えているスケッチは、コンパイル時に `unwritable` の枝が足りないと指摘されます。**

移行: 枝を足してください。`loadImage` などの失敗だけを扱う `switch` なら、`case .unwritable: break` のように何もしない枝で足りますし、`default:` を置いていれば直す必要はありません。
