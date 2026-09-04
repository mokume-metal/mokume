<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色の受け口に数でない値を渡したときの注意が、**口ごとに 1 度ずつ出るようになった**。旗を 1 つ共有していたので、`fill(.nan, 0, 0)` で 1 度鳴った後は `background(.nan, 0, 0)` が無音になっていた。
