<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

矢印を押したまま ⌘Tab で窓を離れると、戻った後もキーが押されたまま残り、物が走り続けていたのを直した ([#2443](https://github.com/mokume-metal/mokume/issues/2443))。窓やアプリが前から退くと、押していたキーと釦は離された扱いになり、`keyReleased()` / `mouseReleased()` が呼ばれる。⌘S のように ⌘ と組んで打ったキーが、押されたまま残ることも無くなった。
