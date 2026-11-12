<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

公開の列挙 `Effect` に、場合 `posterize(levels:)`・`erode`・`dilate`・`opaque` を足しました ([#3716](https://github.com/mokume-metal/mokume/issues/3716))。

移行: `Effect` を `switch` で網羅しているコードは、case が足りないとコンパイル時に指摘されます。`case .posterize(let levels):`・`case .erode:`・`case .dilate:`・`case .opaque:` を足してください。`default:` で受けているコードは変更が要りません。
