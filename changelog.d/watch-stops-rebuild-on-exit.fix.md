<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` を作り直しの最中に終えると、走っていた `swift build` とその配下のコンパイラが残り、すぐに起こし直した見張りが `Another instance of SwiftPM is already running` でそれを待たされていた。見張りは終わるときに走っている作り直しも止め、残さないようになった。

止めた回は `.mokume/build/status.json` に、ビルドの失敗ではなく「見張りを終えたので途中で止めた」と書かれる。
