<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`setup()`・`draw()`・入力のコールバックの外 (`Task` の続き・後片付けの後) から入力の `stop()` を呼んだときの警告が、呼んでいない `detach()` ではなく、呼んだ口の名前 (`AudioIn.stop()`・`Serial.stop()` のように型を付けた名前) を名乗るようになりました ([#2793](https://github.com/mokume-metal/mokume/issues/2793))。対象は `AudioIn`・`Capture`・`TCPServer`・`WebSocketServer`・`UDPPort`・`OSCPort`・`Serial` の `stop()` です。外で呼んでも止まらない (ポートや機材は開いたまま) ことは変わりませんが、警告が「その `stop()` は外では何もしなかった」と言い、型ごとに 1 度ずつ言うので、止まったつもりでいる側が気付けます。中から呼んだ `stop()` は今までどおり閉じます。
