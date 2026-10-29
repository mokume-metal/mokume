<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

MIDI 機材の入力を受け取れるようになりました。`midiDevices()` が繋がっている機材を初めて繋がった順に `MIDIDevice` の並びで返し (`id` は「機材名 #番号」で、抜いて挿し直しても同じ値になります)、`createMIDI(_:)` で 1 台を選ぶと `MIDIPort` が返ります。`draw()` の前に、前のフレームの後に届いたノートオン・ノートオフ・コントロールチェンジが `port.messages` に**全部、届いた順に**入り、コントロールチェンジの現在値は `port.controlChange(1)` (0〜1。まだ届いていなければ `nil`) で読めます。`fill(color(hue: (midi?.controlChange(1) ?? 0) * 360, saturation: 90, brightness: 100))` のように、つまみ 1 本で円の色相を回せます。チャンネルは 1〜16 で数え、省けばどのチャンネルでも最後に届いた値を返します。`plugins` には何も書かず、許可も要りません。

機材を抜くと `port.state` が `disconnected` を名乗り、押していたノートの `noteOff` が最後に入ります (コントロールチェンジの現在値は残ります)。挿し直せば同じ物が `running` に戻ります。ピッチベンドなどほかのメッセージは「読めずに捨てた」と数えて診断に出します。クロックと出力は続けて足します。

`createMIDI(messages:)` は、記録したメッセージの列 (`[MIDIMessage]` をフレームごとに 1 組。`nil` のフレームは抜かれている) を流し、機材が無くても同じスケッチを確かめられます。`MIDIMessage` は `Codable` です。
