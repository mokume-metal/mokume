<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`JSONObject` の説明に、JSON を `Decodable` の型で読む道を足した。`import Foundation` を書き、`assetURL(_:)` で引いた手元の資材を `JSONDecoder` で読む例で、必須のキーが欠けると読み全体が `DecodingError` で失敗し、省いてよいキーは `nil` になる。型を書かずに読む口 (欠けても落ちず、空の値を返して 1 度知らせる) との違いも書いた。公開の口は増えない。
