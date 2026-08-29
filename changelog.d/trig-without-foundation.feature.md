<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチで三角関数 (`sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2`) を呼ぶのに `import Foundation` が要らなくなりました。時刻から位置を出す `circle(width / 2 + cos(time) * 180, height / 2, 120)` のような 1 行が、`import mokume` だけで書けます。Foundation の他の語彙 (`FileManager` など) は今までどおり `import Foundation` が要ります。
