<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`pixels`・`loadPixels()`・`get(_:_:)`・`read(_:)` の説明に、GPU が仕事を打ち切った回は前の絵・前の値を返しうることを書きました。** これらの読む口は投げない約束なので、打ち切られた回も落ちずに返しますが、返る値は前のものでありえて、読んだ値からは区別がつきません (知らせるのは、最初の打ち切りで標準エラーへ 1 度だけ出る 1 行だけです)。絵を書き出すときは `save(_:)`・`beginRecord(_:)`・`mokume render` を使ってください。そちらは打ち切られたフレームを書かず、`mokume render` は欠けた枚があれば名乗って 1 で終わります。振る舞いは変えていません。
