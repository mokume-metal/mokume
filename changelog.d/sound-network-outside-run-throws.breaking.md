<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音と通信の作る口 (`loadSound`・`createAudioIn(file:)`・`createAudioIn(samples:sampleRate:)`・`createTCPServer`・`createWebSocketServer`・`createUDP(listen:send:)`・`createOSC(listen:send:)`) を、`setup()`・`draw()`・入力のコールバックの外 (スケッチや部品の `init()` の中・後片付けの後・`Task` の中) で呼ぶと、黙って鳴らない音・届かないポートを返さずに、その口の型の新しい場合 `notRunning(call:)` を投げるようになりました ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。`AudioFailure`・`NetworkFailure`・`OSCFailure` の 3 つの型に足してあり、`call` には呼んだ口の名前 (`"loadSound(_:)"` など) が入ります。ファイルを読む・ポートを開く前に投げ、投げる前に口ごとに 1 度だけ警告を標準エラーと観測の `warnings` に出します。渡した値が使えない (ポートの番号が範囲の外・標本列が空など) ときは、これまでどおりその場合を先に投げます。カメラと動画の口 (`createCapture`・`createVideo`) と同じ扱いです。

投げない作る口 (合成音の `createSinOsc` などの 11 口・`createAudioIn(device:)`・`createTCPServer(messages:)` などの記録を流す 4 口) は、同じ所で呼んでも今までどおり鳴らない音・何も届かないポートを返しますが、警告が呼んでいない `attach()` ではなく、呼んだ口の名前を名乗るようになりました。走っている所 (`setup()` など) から呼ぶスケッチの動きは変わりません。

移行: この 3 つの型のどれかを `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .notRunning(let call):` の枝を足してください。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、コードの変更は要りません。スケッチの `init()` で音や通信を作っていたなら、これまでも鳴らず届かなかったので、`setup()` へ移してください。
