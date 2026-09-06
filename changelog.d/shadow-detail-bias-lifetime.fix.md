<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

影の設定 6 つのうち、`shadowDetail()` と `shadowBias()` だけがフレームを越えて残っていたのを直した。ほかの 4 つ (`shadows()` / `shadowRange()` / `castShadow()` / `receiveShadow()`) と同じく、フレームの境目で既定へ戻る。

影は「何を描くか」の側の設定なので、`draw()` の中で毎フレーム書くのが約束である。これまでは細かさとにじみの逃がしだけが「一度書けば残る」ふるまいをしていたため、条件によって書いたり書かなかったりするスケッチで、書かなかったフレームに前の値が残っていた。**毎フレーム同じ細かさを書き続けても焼き付け先は作り直さない**ので、書き直しが重さになることはない。
