<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

矩形へ流し込む `text(s, x, y, w, h)` の既定の折り返し (`textWrap(.word)`) が、語の切れ目を空白だけでなく Unicode の行分割の規則 (UAX #14) で決めるようになりました。和文の行頭に「、」「。」「」」が来ず、行末に「「」が残らなくなり、和欧混在の文が空白の手前で短く切れずに詰まります。欧文の折り位置は空白の後ろのままですが、ハイフンやスラッシュの後ろでも折れるようになります。小書きの仮名と長音の前では折りえます。`textWrap(.character)` は変わりません。
