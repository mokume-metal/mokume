<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`swift` が `PATH` に無いとき、`mokume run` と `mokume watch` が「Cannot find swift. Install the Xcode command line tools」と名乗って終わるようになった。

これまでは道具立てが見つからないことに気付けず、空の出力を「宣言が読めない」「走らせるものが無い」と読んで `Check that Package.swift declares an executable in products` と案内していた — 原因は道具立てなのに、Package.swift を疑わせていた。`watch` は見張りを始める前に断る (見張りの中からは `PATH` を直せないので、回り続けても回復しない)。
