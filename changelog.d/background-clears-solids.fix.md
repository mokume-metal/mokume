<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`background(_ color:)` より前に置いた立体が消えずに残っていたのを直しました。面全体を塗り直すのだから、下に隠れるものは平面と同じく立体も残りません。これまでは立体の頂点だけが捨てられずに残り、絵に出てしまうだけでなく、後から置いた立体と同じ列に混ざって材質や光まで後の列のものが効いていました。
