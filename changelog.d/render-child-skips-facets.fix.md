<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume render` の書き出しが、同じ場所の観測・入力・つまみの区画 (`.mokume/observe` / `input` / `params`) を開かなくなった ([#1619](https://github.com/mokume-metal/mokume/issues/1619))。これまでは `mokume watch` を回したまま書き出すと、見張りが置いた区画を書き出しの子も開き、窓口から送った入力やつまみの値が書き出した連番に混ざりえた。保存の入れ替えの瞬間に見張りの要求を取り合い、`params/report.json` も起動しただけで書き換えていた。

作者が合わせて保存した値 (`.mokume/state/params.json`) は区画と別の口なので、書き出しにもこれまでどおり戻る。代わりに、書き出しの間は窓口の `observe` で進み具合を見られない (見張りが居れば、観測は見張りの子が応える)。
