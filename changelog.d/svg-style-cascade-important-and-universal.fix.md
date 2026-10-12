<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` が読む SVG の `<style>` の優先を、CSS のとおりにした。2 つの食い違いを直している。

**`<style>` の `!important` が効くようになった。** これまでは `!important` を落として書いた場所だけで優先を決めていたので、`<style>rect { fill: red !important }</style>` と `<rect style="fill: blue" …/>` の組はブラウザでは赤になるのに、mokume では `style` 属性が勝って青になっていた。いまは赤になる。`!important` の宣言は属性・ふつうの規則・`style` 属性のすべてに勝ち、`<style>` の `!important` どうしは詳細度の順 (`*` < 要素名 < クラス) で、`style` 属性の `!important` にだけ負ける。`!` と `important` の間の空白 (`! important`) と大文字小文字 (`!IMPORTANT`) も同じに読む。

**`*` の規則が、要素名の規則に勝たなくなった。** `<style>rect { fill: red } * { fill: blue }</style>` のように `*` を後ろに書くと、書いた順で `*` が要素名の規則を上書きして青になっていた (CSS では要素名のほうが詳細度が高く、書いた順によらず赤)。いまは書いた順によらず赤になる。`*` は属性より強く、クラスの規則より弱い。

`!important` を使った SVG や、`*` の規則を後ろに書いて要素名の規則を打ち消していた SVG は、色が変わりうる (ブラウザでの見え方に揃う向き)。`!important` を使わず、`*` の規則も使わない SVG の読み方は変わらない。
