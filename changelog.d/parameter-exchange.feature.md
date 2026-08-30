<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

宣言した値を、走らせたまま外から読んで書き換えられるようにした。作業ディレクトリに `.mokume/params/` を置いて起動すると、いまの値と宣言 (型・動ける幅・許した候補) が `report.json` に出て、`request.json` に書き換えを置けば次のフレームで入る。

**書き換えがどうなったかは、必ず面に出る。** 知らない名前・型の違い・候補の外は理由つきで `rejected` に、動ける幅へ収めたものは収める前後の値つきで `clamped` に載る。応答は要求の識別子を返すので、壁時計で待たずに反映を確かめられる。1 つも入らなかったときも応答は書かれる (届いていないことと区別できる)。

やりとりの形は `Schemas/params-request.schema.json` と `Schemas/params-report.schema.json` が正典。
