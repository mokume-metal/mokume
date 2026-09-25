<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

マウスの釦を数ではなく名前で指すようになりました。`mouseButton` が新しい `MouseButton` 型の値を返し、手本の `LEFT` / `RIGHT` / `CENTER` と同じ綴りの `.left` / `.right` / `.center` で比べられます。

```swift
func mouseReleased() {
    if mouseButton == .right { marks.removeAll() }
}
```

これまでの `mouseButton` は macOS の釦の番号 (0 = 左・1 = 右・2 = 中) を `Int` のまま返していました。Processing の定数 (`LEFT` は 37) とも、ブラウザの番号 (1 が中・2 が右) とも並びが違うため、手本を写した `mouseButton == 37` は常に偽になり、`mouseButton == 2` は右ではなく中の釦を指していました。**型が変わったので、数で比べる書き方はコンパイルの時点で止まります。**

あわせて、**まだ何も押していないときは `nil` を返す**ようになりました (これまでは左の釦と同じ 0 を返していたので、押す前から「左が押された」と読めました)。押しても離しても入れ替わるのはこれまでどおりで、`mouseReleased()` の中から離した釦を読めます。

移行:

- `mouseButton == 0` → `mouseButton == .left`、`== 1` → `== .right`、`== 2` → `== .center`
- 4 番目以降の釦 (戻る・進むなど) は `MouseButton(rawValue: 3)` のように番号で表せます
- `switch mouseButton` の `case 0:` は `case .left:` と書き換えます。まだ何も押していないときの `nil` は `default:` の枝へ落ちます
- `InputState.button` も `MouseButton?` に、`InputEvent.mouseDown` / `mouseUp` の `button:` も `MouseButton` になりました
- 外から送る `.mokume/input` の `button` は今までどおりの数 (macOS の番号) で、送り手を変える必要はありません
