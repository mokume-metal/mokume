<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

説明文の例で、必須の資源 (`createImage`・`createGraphics`・`makeShader`・`loadModel` など) を `try!` で作っていたものを、`func setup() throws` の中の `try` に書き直した。読めなければ強制終了ではなく、起動の失敗として理由つきで止まる。`try?` は無くても絵が成り立つ資源の例に絞り、省いてよい理由を添えた。入口の「Swift で 3 つだけ違うこと」の 3 番は、必須の資源を `setup() throws` で受ける形を先に示し、`try?` を任意の資源の形として後に置き、「Processing には `try` が無い」という言い方を外した。
