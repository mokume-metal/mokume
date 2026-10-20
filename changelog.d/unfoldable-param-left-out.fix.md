<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

自作の `ParamRepresentable` が型の零を受け付けず、非有限の値で生まれたとき、その宣言だけを保存 (`params.json`) と応答 (`report.json`) から外すようにした。

これまでは非有限の値が載ったまま残り、他のつまみの値も含めて保存も応答も書けなくなっていた。外した宣言は、有限の値を代入するか外から書き込むと、次の保存と応答に戻る。外したことは起動時に 1 度だけ標準エラーへ名乗る。
