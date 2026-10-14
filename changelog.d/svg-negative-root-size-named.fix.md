<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` で、根や入れ子の `<svg>` の `width` / `height` が負の値 (`width="-5"`・`style="width:-5px"`) のとき、何も描かないまま黙らず、捨てたものとして知らせるようにした (`<svg width="-5">`)。読めない値 (`abc` など) と同じ扱いで、描く・描かないは変わらない。`0` は SVG の約束どおり描かないだけで、これまでどおり知らせない。
