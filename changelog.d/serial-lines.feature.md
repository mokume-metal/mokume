<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

シリアルポートから行を受けられるようになりました (Processing の `Serial` に当たります)。`serialPorts()` が繋がっているポートの一覧を返し、`port = try createSerial(serialPorts()[0], baudRate: 9600)` で開くと、`draw()` の前に、前のフレームの後に届いた行を全部、届いた順に `port.lines` へ入れます。Arduino の `Serial.println(analogRead(A0))` が送る `512\r\n` は `"512"` として届くので、そのまま `Float(line)` で読めます。一覧は USB で繋いだもの (Arduino など) を先に並べるので、1 台だけ挿していれば `serialPorts().first` がそれになります。`plugins` には何も書かず、OS の許可も要りません。

設定はボーレートだけで (8 ビット・パリティなし・ストップビット 1)、送る向きはまだありません。ポートが繋がっていない・他のアプリ (Arduino IDE のシリアルモニタなど) が使っているときも作れて、`state` が `unavailable` になり、挿されたら・空けば受け始めます。USB を抜くと `disconnected` になり、挿し直せば戻ります。開いている間は他のアプリがそのポートを開けないので、Arduino IDE で書き込む前に `stop()` するかスケッチを止めてください。`createSerial(lines:)` は記録した行の列をフレームごとに 1 束ずつ流し、機材なしで同じスケッチを確かめられます。
