<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

走っているスケッチへ差込口を足し・外す `attach(_:)` / `detach(_:)` を追加しました。`createCapture()` のような「呼べば使える」機能を作るための口で、`plugins` に書かせずに、作る口の中で入り口や出口を足せます。外のパッケージも同じ形を作れます。あわせて、外から届く値の最新の 1 つを預かる `ExternalInput` と、出どころの状態 `SourceState` を追加しました。入り口が `report` で状態を名乗ると、観測の応答の `inputs` に「許可を待っている・機材が無い・抜かれた」と最後に値が届いたフレームが載ります。
