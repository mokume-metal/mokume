<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画に触れる PR を merge queue へ戻すとき (`make catch-up`)、**main の取り込みを push しなくなった**。以前は取り込みを push する必要があり、その push でルールセットが承認を落とすので、承認が要る PR は他の PR が入るたびに押し直しになっていた。

覆いの判定は「PR の head の木」ではなく「**手元が実際に回した木**」を見るようになった。何を回したかは `local-render` の報告が名乗る。衝突を解いた合流だけは今までどおり push する — 入る中身が本当に変わるので、承認のやり直しが正しい。
