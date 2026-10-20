<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

フレームの `draw`・`flush` (描き切り)・`present` (差し出し) の区間が Instruments の「Points of Interest」(subsystem `mokume`) に並ぶようになった。

CPU の時間をどの段が食っているかを、GPU の仕事 (Metal System Trace) と同じ時間軸で見比べられる。1 フレームあたりの代償は数 µs。あわせて内部では、フレームごとの GPU の投入の幅 (その回の投入の最初の開始から最後の終了まで) を投入の結末から集めるようにした。待ちは増えない。この幅は GPU の稼働時間や使用率ではなく、観測の報告にはまだ出さない。
