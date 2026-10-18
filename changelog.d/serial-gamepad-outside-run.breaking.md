<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createSerial(_:baudRate:)` を `setup()`・`draw()`・入力のコールバックの外 (スケッチや部品の `init()` の中・後片付けの後・`Task` の中) で呼ぶと、足されていない `Serial` を返さずに、`SerialFailure` の新しい場合 `notRunning(call:)` を投げるようになりました ([#2837](https://github.com/mokume-metal/mokume/issues/2837))。これまでは投げずに `Serial` を返しましたが、走っているスケッチへ足されないのでポートは開かれず、`state` は `.unavailable` のまま変わりませんでした — 「挿されたら・空けば受け始める」と見分けが付かず、警告も呼んでいない `attach()` を名乗っていました。`call` には呼んだ口の名前 (`"createSerial(_:baudRate:)"`) が入り、ポートを開く前に投げ、投げる前に 1 度だけ警告を標準エラーと観測の `warnings` に出します。ボーレートが使えないとき (`baudRate: 0` など) は、外で呼んでもこれまでどおり `invalidBaudRate` を先に投げます。音と通信の作る口 ([#2740](https://github.com/mokume-metal/mokume/issues/2740)) と同じ形です。

投げない作る口 — `createSerial(lines:)`・`gamepads()`・`createGamepad(inputs:)` — は、外で呼んでも今までどおり足されていないものを返しますが、警告が呼んでいない `attach()` ではなく、呼んだ口の名前を名乗るようになりました。走っている所 (`setup()` など) から呼ぶスケッチの動きは、4 つとも変わりません。

移行: `SerialFailure` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .notRunning(let call):` の枝を足してください。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、型の上の変更は要りません。外で `createSerial(_:baudRate:)` を呼んでいたコードは、呼ぶところを `setup()` へ移してください。外で作った `Serial` は走っているスケッチへ足されないので、これまでも何も受けていません。
