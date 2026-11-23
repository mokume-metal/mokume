<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run --remote` と `mokume watch` でつまみを動かすと、いつ・どのつまみが・何から何へ・どこから (`phone`・`window`) 変わったかが、ターミナルに時刻付きの 1 行で残るようになりました (例: `12:03:04.512  radius  0.40 → 0.55  (phone)`)。スライダーを引いている間は書かず、止まった値で 1 行にまとめます。範囲へ収められた値は、スケッチが実際に受け取った値で書きます。スケッチ自身の `print` の出方は変わりません ([#4130](https://github.com/mokume-metal/mokume/issues/4130))。
