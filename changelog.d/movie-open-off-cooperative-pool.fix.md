<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`createVideo(_:)` が動画を開くときのトラックの読み込みが、Swift の協調プールの空きを待たなくなりました。** これまでは、作品が `Task.detached` などで協調プールのスレッドを同期の重い仕事で埋めている間に動画を開くと、開く呼び出しが読み込みの順番を待って返らないことがありました (コアの少ない機械ほど起きやすい)。読み込みの完了を AVFoundation の側のスレッドで受けるようにしたので、この待ちでは詰まりません。
