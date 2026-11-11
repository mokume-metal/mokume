<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume render --out` の `.png` で終わらない連番 (`out/f-####.jpg`・`out/f-####.gif`・`out/f-####.tif` など) と、`SketchRuntime.renderFrame(to:)` の `.png` で終わらない URL が、PNG の中身を別の名前で書かずに断るようになりました ([#3961](https://github.com/mokume-metal/mokume/issues/3961))。

どちらも書けるのは PNG だけで、これまでは拡張子と中身の違うファイルができていました。`render` はビルドの前に使い方の誤りとして止まり、`renderFrame(to:)` は描かずに `ImageFailure.unwritable(path:reason:)` を投げてファイルを作りません。どちらの文面も、受ける名前を名指します。`.png` と `.PNG` は今までどおり受けます。

移行:

- PNG の連番にするなら、`--out out/f-####.gif` を `--out out/f-####.png` に変えます
- アニメーション GIF にするなら、番号の場所 (`#` の並び) を外して `--out out/movie.gif` とします
- `renderFrame(to:)` に `frame.jpg` や拡張子の無い `frame` を渡していたら、`frame.png` に変えます

```swift
// 前
try runtime.renderFrame(to: URL(fileURLWithPath: "out/frame.jpg"))
// 後
try runtime.renderFrame(to: URL(fileURLWithPath: "out/frame.png"))
```
