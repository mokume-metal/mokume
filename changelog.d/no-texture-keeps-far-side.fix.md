<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

透けた画素を持つ絵を `texture` で貼った立体を置いた後で `noTexture()` を呼ぶ (あるいは `pop()` で絵を外す) と、その立体の裏を向いた面が捨てられ、透けた画素から見えるはずの奥の面が消えていたのを直した。裏面を捨てるかは、形を置いたときの絵・混ぜ方・断片・塗りの不透明度で決まり、後から変えた設定は既に置いた形に効かない。
