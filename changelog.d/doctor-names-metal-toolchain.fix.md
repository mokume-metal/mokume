<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume doctor` が、シェーダを組む道具 (`metal`) を使えるかを「環境の前提」に並べるようになった。Xcode 26 では Metal Toolchain が Xcode とは別のコンポーネントで、入っていないと最初のビルドが `unable to spawn process 'metal'` で止まる。見つからないときは `xcrun` が言った理由とあわせて、入れ方 (Xcode の Settings → Components、または `xcodebuild -downloadComponent MetalToolchain`) を同じ出力に出す。doctor 自身は何も入れない。
