<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

形を `endShape()` で閉じないまま `beginShape()` をもう一度呼ぶと、前の形の点が何も言わずに捨てられていたので、注意を 1 度出すようにしました。前の形が描かれないのは今までどおりで、絵は変わりません。`endShape()` の書き忘れに気付けるようになります。
