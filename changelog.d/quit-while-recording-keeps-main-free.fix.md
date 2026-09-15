<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`beginRecord()` で動画を撮っている最中にスケッチを終えたとき、動画を閉じ終えるまでの間にアプリケーションの main スレッドを塞がなくなりました。** これまでは、書き出しを閉じる `AVAssetWriter` の最終化を main スレッドを止めたまま待っていました。Apple はこの形を失敗しうるとしています。いまは macOS の「終了を後で返す」仕組みで最終化を待ち、閉じ終えてから終わります。待っている間はフレームを進めず、窓の × を押しても終わりを重ねません。
