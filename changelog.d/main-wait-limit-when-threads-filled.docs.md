<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

作品が `Task.detached` などの並行の仕事で、同期の待ち (`DispatchSemaphore.wait()` など) のまま OS のスレッドをコア数ぶん以上塞いでいると、本体が main で待つ動画の読み出しと書き出しが進まず、窓ごと止まることがある、という**限界**を説明に書きました。`createVideo` と `Movie` (動画のコマを読む待ち)、`beginRecord` と `save` (書き出しの枠を待つ待ち。連番は `beginRecord` を通ります) の説明に、避け方も添えています。

避け方は、重い同期の仕事の優先度を下げる (`Task.detached(priority: .utility) { … }`) か、待たずに分けることです。この限界は本体の側では防げません。書き出しの待ちに期限を置くと絵を落とすことになるので置かず、動画の読み出しは OS の内部の待ちなので逃がせません。挙動は変わりません。理由と退けた案は [ADR-0010](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md) の「影響」にあります。作品で止まった報告が出たら、専用のスレッドへ出す案や期限を置く案を比べ直します。
