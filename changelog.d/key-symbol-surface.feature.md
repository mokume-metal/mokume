<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

キーを数ではなく名前で指せるようになりました。`keyCode` が新しい `Key` 型を返し、`isKeyDown(_:)` も同じ型を取ります。

```swift
if keyCode == .space { plant() }
if isKeyDown(.arrowUp) { y -= 4 }
```

**破壊的変更**: `isKeyDown(_ code: Int)` は無くなりました。生の数を渡していたコードは `Key` の綴りへ書き換えてください (名前の無いキーは `Key(rawValue: 49)` で表せます)。

mokume が運んでいるのは macOS の仮想キーコードで、p5.js や Processing の `keyCode` とは体系が違います。p5 を写した `keyCode == 32` はこれまで黙って別のキーを指していましたが、**型が変わったのでコンパイルの時点で止まります**。外から送る `.mokume/input` の `code` は今までどおりの数で、送り手を変える必要はありません。
