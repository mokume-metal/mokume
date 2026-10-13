<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` で、根の `<svg>` の `width` / `height` を CSS (`style` 属性・`<style>`) で書いた SVG が、属性で書いたときと同じ大きさで読まれるようにした。これまでは CSS の値が無視され、`<svg viewBox="0 0 100 200" style="width:50px">` は 100×200 のまま置かれていた。いまは 50×100 になる。属性と CSS の両方に書けば CSS が勝つ (`<style>` の優先と同じ規則)。CSS が勝つので、`width="24"` に `style="width:100%"` を重ねた根は、`width:100%` が勝って `viewBox` の大きさ基準になり、`height:auto` を重ねた根も属性の高さを捨てて `viewBox` の大きさ基準になる。CSS で読めない値 (`1em`・`calc()` など) は CSS と同じに捨てて名乗り、下の読める宣言 (属性など) を採る。`initial` と `unset` は `auto` と同じに読む。

あわせて、`auto` 以外の読めない値を黙って捨てず、捨てたものとして知らせるようにした。根と入れ子の `<svg>` の `width` / `height` (`height="abc"`・空・読めない単位。CSS で書いた値も同じ)、入れ子の `<svg>` の `x` / `y`、`rect` の `rx` / `ry` が対象で、大きさと形は今までどおり「書いていないのと同じ」に読む。`width` / `height` / `rx` / `ry` の `auto` と、書いていない口は知らせない。`<ellipse>` の `rx` / `ry` の `auto` は `<rect>` と同じに読み (片方が `auto` ならもう片方を使う)、これまで楕円ごと描かれなかったものが描かれる。`<rect>` の `width="auto"` は名乗らず、描かない。

根の `width` / `height` を CSS で書いていた SVG は、形の大きさと位置が変わる。属性だけで書いた SVG の大きさは変わらない。
