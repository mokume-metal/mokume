<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音と通信の作る口 (`loadSound`・`createAudioIn(file:)`・`createAudioIn(samples:sampleRate:)`・`createTCPServer`・`createWebSocketServer`・`createUDP(listen:send:)`・`createOSC(listen:send:)`) を、`setup()`・`draw()`・入力のコールバックの外 (スケッチや部品の `init()` の中・後片付けの後・`Task` の中) で呼ぶと、黙って走っているスケッチへ足されていないものを返さずに、その口の型の新しい場合 `notRunning(call:)` を投げるようになりました ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。`AudioFailure`・`NetworkFailure`・`OSCFailure` の 3 つの型に足してあり、`call` には呼んだ口の名前 (`"loadSound(_:)"` など) が入ります。ファイルを読む・ポートを開く前に投げ、投げる前に口ごとに 1 度だけ警告を標準エラーと観測の `warnings` に出します。走っていない所で投げるのはカメラと動画の口 (`createCapture`・`createVideo`) と同じですが、順序が 1 つ違います。渡した値が使えない (ポートの番号が範囲の外・標本列が空など) ときは、これまでどおりその場合を先に投げます — `createAudioIn(samples: [], sampleRate: 48_000)` を外で呼ぶと `.empty` です (カメラの `createCapture(frames: [])` は、面を確かめるのが先なので `notRunning` です)。

投げない作る口は、同じ所で呼んでも今までどおり足されていないものを返しますが、警告が呼んでいない `attach()` ではなく、呼んだ口の名前を名乗るようになりました。合成音の `createSinOsc` などの 11 口は、音の流れをまだ走っているスケッチへ足していなければ鳴らない音を返します (`setup()` などで先に合成音を作ってあれば、その流れに入って鳴ります)。`createAudioIn(device:)` は何も聞かない入力を、`createTCPServer(messages:)` などの記録を流す 4 口は何も届かないポートを返します。走っている所 (`setup()` など) から呼ぶスケッチの動きは変わりません。

**代償: 走る前に作った送り専用の UDP・OSC のポートは、これまで届いていたものが `notRunning` になります。** たとえば `final class Remote: Sketch { var osc: OSCPort?; init() { osc = try? createOSC(listen: 9000, send: ("127.0.0.1", 7000)) }; func draw() { osc?.send("/x", mouseX) } }` は、これまで受けこそしないものの送れていました (送るポートは足されていなくても送り、スケッチが終わっても閉じられずに残っていました)。いまは `osc` が `nil` になり、何も送りません。`createUDP(listen:send:)` も同じです。作るところを `setup()` へ移してください。

移行: この 3 つの型のどれかを `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .notRunning(let call):` の枝を足してください。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、型の上の変更は要りません。走る前に作っていたコードは、次のどれでも作るところを `setup()` へ移してください。

- スケッチや部品の `init()` で作っていた: 音は鳴らず、受けるポートは受けていなかった (送るだけのポートは上の代償のとおり届いていた)。いまは投げます
- 外で作ったものを、`setup()` で公開の `attach(_:)` に渡して足していた (これまでの警告 "attach() is only accepted from inside setup() …" がこの直し方へ誘っていました): 投げる 7 口では、作るところで投げるようになったので、作るところごと `setup()` へ移します。投げない口のうち `createAudioIn(device:)` と記録を流す 4 口は、これまでどおり `setup()` で `attach(_:)` に渡せば足されます
- 自作の `Plugin` の中や `plugins` の並びを作るところで作る口を呼んでいた: `plugins` はスケッチの `setup()` より前に読まれるので、そこで呼ぶ投げる口は投げます。`Plugin` には入り口を自分で作って渡すか、`setup()` で作ります
- `try!` で受けていた: これまでは黙って足されていないものが入っていましたが、いまは投げてプロセスが止まります。`setup()` へ移すか、`try?` や `do`/`catch` で受けます
