<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**ウィンドウの題名を走っている最中に変え、ウィンドウが前にあるかを読めるようになりました。** `windowTitle(_:)` は題名を変え、`focused` はウィンドウが前にある (キーを受け取る) かを `Bool` で返します。Processing の `windowTitle()` と `focused` に当たります。

```swift
func mousePressed() { windowTitle("clicked \(frameCount)") }

func draw() {
    if !focused { noLoop() }
    background(20)
}
```

`mokume watch` の下では、題名は道具の作品のウィンドウに付き、`focused` は道具のウィンドウ (作品のウィンドウかプレビュー) が前にあるかを返します。`SketchView` では `windowTitle(_:)` は何もせず 1 度だけ警告し (題名はホストのアプリのもの)、`focused` はビューを載せたウィンドウが前にあるかを返します。ウィンドウの無い実行 (`mokume render`) では `focused` はいつも `true` で、`windowTitle(_:)` は何もしません。ウィンドウが前から退くと、ウィンドウで押していたキーとボタンは離された扱いになり、その `keyReleased()`・`mouseReleased()` の中から読む `focused` は既に `false` です。**退いても、外から注入した押下 (入力の線・MCP の `keyDown`・`mouseDown`) は離しません** — 注入した側が解放を送るまで押されたままなので、`focused` が `false` の間も押されたままでありえます。外から送る線 (`.mokume/input`・MCP の `input`) にも `{"type": "focusChanged", "focused": false}` が加わりました (`focused` は必須で、`focusChanged` でだけ読みます。この知らせそのものは押下を離しません)。スキーマの版は動かしていません。

**公開の `InputEvent` を広げたので、破壊的な変更である。** `InputEvent` に場合 `focusChanged(focused:)` を足した。**移行**: `InputEvent` を網羅して `switch` していたなら、`.focusChanged` の場合を足す (ウィンドウが前に出た・退いたを持つ)。値を組み立てる側は書き換えなくてよい。
