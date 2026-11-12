<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ファイルや URL の中身をそのままバイト列 (`[UInt8]`) で読み書きする `loadBytes(_:)`・`requestBytes(_:)`・`saveBytes(_:_:)` を入れました (Processing の `loadBytes()`・`saveBytes()`)。探す場所・URL の扱い・読めないときに `DataFailure` を投げることは `loadStrings(_:)` と同じで、`requestBytes(_:)` はフレームを止めずに読みます。`saveBytes(bytes, "out/blob.bin")` は途中のディレクトリを作り、書きかけを残さず、書けなければ `DataFailure.unwritable` を投げます。引数は `saveStrings(_:_:)` と同じく値が先・置き場が後で、Processing の `saveBytes(filename, data)` とは逆です。
