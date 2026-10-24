<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`setup()` を `throws` で書けるようになりました** ([#2401](https://github.com/mokume-metal/mokume/issues/2401))。読み込みや組み立ての失敗を `try?` で捨てて、Optional の資源と毎フレームの `guard let` で持つ代わりに、`var cat: Image!` と `func setup() throws { cat = try loadImage("assets/cat.png") }` と書けます。投げたら、`draw()` を 1 度も呼ばずにスケッチは起動の失敗として止まり (終了コードは 1)、標準エラーに `The sketch could not start.` と、投げた失敗の全文 (何を読めなかったかと、次にすること) が出ます。窓で走らせても `mokume render` で書き出しても同じ文面で止まります。投げる型は問わず、`ImageFailure`・`ShaderFailure` などをそのまま通せます。`setup()` で `noLoop()` を呼んでから投げても、以後のフレームは同じ失敗を投げ続け、入力は失敗したスケッチへ配られません (観測の応えにも理由が載ります)。窓の経路は、`setup()` で開いたカメラ・音・シリアル・ソケットを閉じてから終わります。

投げない `func setup()` を書いたスケッチは、書き換えずにこれまでどおり組めて、呼ばれます。`async` にはしていません (`async` にすると、既存の同期の `setup()` が呼ばれなくなるため)。

移行: `setup()` が投げたことを運ぶため、公開の列挙 `RenderFailure` に場合 `setupFailed(reason:)` が増えました。`RenderFailure` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .setupFailed(let reason):` の枝を足してください (`reason` は投げた失敗の全文です)。`default:` で受けているコードは変更が要りません。
