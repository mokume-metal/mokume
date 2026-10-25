<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**ファイルを選ばせるダイアログを出せるようになりました。** `selectInput(_:)` は、Processing の `selectInput(prompt, callback)` に当たる口で、コールバックの代わりに `async` で、選んだファイルの絶対パスを返します。取り消すと `nil` です。

```swift
func mousePressed() {
    Task {
        if let path = await selectInput("CSV を選ぶ") {
            table = try? loadTable(path, header: true)
        }
    }
}
```

`requestImage(_:)` などと同じく、`setup()` かコールバックの中で `Task` を起こし、そこから呼びます。待っている間もフレームは回ります。ダイアログを出すのは窓を持つ側です — 直に走らせた窓ではその窓が、`mokume watch` の下では (スケッチは窓を持たないので) 道具の作品の窓が出します。1 度に待てる `selectInput` は 1 つで、待っている間にもう 1 度呼ぶと、前の待ちは `nil` で終わります。`await` が戻る時刻がどのフレームの境界か、`noLoop()` の間や `render` で届いた結果の扱いは、`request…` の口と同じく [#2760](https://github.com/mokume-metal/mokume/issues/2760) と合わせて決めるので約束ではありません。macOS の窓で出します (iOS と `SketchView` のホストからの出し方は未定)。保存先やフォルダを選ばせる口はまだありません。

結果は入力の出来事 `fileSelected` として届くので、外から差し替えられます (`.mokume/input` と MCP の `input`): `{"type": "fileSelected", "paths": ["/tmp/a.csv"]}` で待ちが終わり、`"paths": []` は取り消し (`nil`) です。`paths` の無いもの・2 本以上・`/` で始まらない要素を含むものは、取り消しとは読まず、読めない 1 件として `ignored` に数えます。待っている `selectInput` が無いときに送った結果は捨て、応答の `warnings` で名乗ります。スキーマの版は動かしていません。

**公開の `InputEvent` を広げたので、破壊的な変更である。** `InputEvent` に場合 `fileSelected(path:)` を足した。**移行**: `InputEvent` を網羅して `switch` していたなら、`.fileSelected` の場合を足す (選んだパス。取り消しは `nil`)。値を組み立てる側は書き換えなくてよい。
