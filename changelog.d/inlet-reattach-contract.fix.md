<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`detach(_:)` で外した入り口を `attach(_:)` で足し直しても、足す前と同じに動くようになった。これまで `Gamepad`・`OSCPort`・`TextPort` (`TCPServer`・`TCPClient`・`WebSocketServer`・`WebSocketClient`・`UDPPort`)・`Movie` は、外したことを最後と思い込んでいて、足し直した後に食い違っていた ([#3122](https://github.com/mokume-metal/mokume/issues/3122))。

- `Gamepad`: 足し直した後も、`gamepads()` が同じ 1 台を返す。これまでは同じ機材のパッドがもう 1 台作られ、2 台が生きていた
- `OSCPort`・`TextPort` の仲間: 足し直した後も `send(_:)`・`write(_:)` が送れる。これまでは受信だけが戻り、送ると `This ... is stopped` と知らせて送らなかった
- `Movie`: 足し直した後、`state` と観測の `inputs` が `running` に戻る。これまでは映っているのに `stopped` と名乗り続けた

入り口 (`Inlet`)・出口 (`Outlet`) の `open()` は、外して足し直すと `close()` の後にもう 1 度呼ばれる、と説明に書いた。自作の入り口は、`close()` を最後と思い込まずに、`open()` で自分を使える状態へ戻す。
