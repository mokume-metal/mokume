<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**窓へ落としたファイルを、スケッチが受け取れるようになりました。** `func fileDropped(_ paths: [String])` を書くと、ファイルを窓へ落としたフレームの頭で 1 回呼ばれ、落とされたファイルの絶対パスが並んで届きます。落とした所へ `mouseX`・`mouseY` が動くので、呼ばれた中から読めます (`mouseMoved()` は呼ばれません)。パスは `loadImage`・`loadTable` などにそのまま渡せます。

```swift
var photo: Image?
func fileDropped(_ paths: [String]) { photo = try? loadImage(paths[0]) }
```

ファイルの URL だけを受けます (ブラウザから落とした文字列や URL は受けません)。macOS の自前の窓と、`mokume watch` の道具の窓で受けます。道具の窓では、1 回の落としが子へ渡る 1 行が 1 MiB (1,048,576 バイト・長いパスでおよそ 5000 本以上) を越えると、子へ流さずに捨て、`mokume watch` が 1 度だけ `Dropped an input event of N bytes: …` と名乗ります (分けて送ることはしません)。`SketchView` に埋め込んだ面は受けません (窓はホストのもので、ホスト側のドロップと取り合わない)。iOS とセキュリティスコープ付きの URL は未定です。**ラベルを違えて `func fileDropped(paths: [String])` と書くと、コンパイルは通りますが呼ばれません。** 外から送る線 (`.mokume/input`・MCP の `input`) にも `{"type": "fileDropped", "paths": ["/tmp/a.png"], "x": 10, "y": 20}` が加わりました (`paths` は `fileDropped` でだけ読み、空の配列や、`/` で始まらない要素 (空文字列・URL・相対パス) を含むものは、読めない 1 件として `ignored` に数えます。位置が有限でないときは位置だけを捨てて、パスは届きます)。スキーマの版は動かしていません。

**公開の `InputEvent` を広げたので、破壊的な変更である。** `InputEvent` に場合 `fileDropped(paths:x:y:)` を足した。**移行**: `InputEvent` を網羅して `switch` していたなら、`.fileDropped` の場合を足す (落としたパスと位置を持つ)。値を組み立てる側は書き換えなくてよい。
