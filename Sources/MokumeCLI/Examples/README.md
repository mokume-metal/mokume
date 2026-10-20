<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Examples

道具 (`mokume examples` / `mokume new <名前> --from <例>`) に同梱する作例の置き場。

**中身は生成物で、コミットしない。** 説明文 (`///`) の中の例から `scripts/bundle-examples.py` が作る
(`make cli-examples`。配布物を束ねる `make cli-dist` は先に自分で呼ぶ)。この 1 枚だけが追跡されるのは、
資源の宣言 (`Package.swift` の `.copy("Examples")`) が置き場の実在を要るからで、束を作っていない手元でも
`swift build` が通るようにしてある。束が無いまま走らせた道具は、束が無いと名乗る。

形と選ぶ規則は `scripts/bundle-examples.py` の冒頭、読む側は `Sources/MokumeCLI/Examples.swift`。
