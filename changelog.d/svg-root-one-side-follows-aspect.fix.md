<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` で、根の `<svg>` に `viewBox` と `width` か `height` の片方だけを書いた SVG が、ブラウザで開いたときと同じ大きさになるようにした。これまでは書いていない側が `viewBox` の大きさのままになり、`<svg width="50" viewBox="0 0 10 20">` は 50×20 の枠に等倍で写って、絵が拡大されずに右へ 20 ずれるだけだった。いまは書いていない側を `viewBox` の縦横比から決め、50×100 に 5 倍で写る。`width="auto"` と読めない値も、書いていないのと同じに扱う。

片方だけを書いた SVG を読んでいた作品は、形の大きさと位置が変わる (ブラウザで開いたときの大きさに揃う向き)。両方を書いた SVG・どちらも書かない SVG・`viewBox` の無い SVG の読み方は変わらない。
