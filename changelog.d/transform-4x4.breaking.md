<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

変換を表す型の名前が `Transform2D` から `Transform` に変わった。奥行きを含む変換 (`rotateX` など) も同じ状態へ積むようになったためで、`applyMatrix(_:)` に渡す型がこれにあたる。移行は型名の書き換えだけで、平面だけを扱っているコードの絵は 1 画素も変わらない。
