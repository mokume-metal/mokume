<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

MIDI の入力で、外から届くクロックを受けて**拍を数える**ようになりました ([#3591](https://github.com/mokume-metal/mokume/issues/3591))。`createMIDI(_:)` で選んだ機材 (DAW の「MIDI クロックを送る」設定、ドラムマシンなど) からクロックが届くと、`MIDIPort` の `beat` (0 から) が **24 クロックで 1 拍**ずつ進みます。`background(midi.beat % 2 == 0 ? 30 : 200)` のように書くと、拍ごとに背景が切り替わり、DAW のテンポを変えれば切り替わる間隔もついてきます。

数え方は MIDI 1.0 の仕様どおりです。**開始 (Start) で 0 に戻って数え始め**、**停止 (Stop) で数えるのを止め** (止めている間に届くクロックは拍を進めません)、**再開 (Continue) で止めた位置から続けます**。曲の位置 (Song Position Pointer) は、MIDI 1.0 では主に止めている間に届き、16 分音符 1 つを 6 クロックとして位置を移します (`SPP = 8` の後に再開すれば、拍は 2 から数えます)。走っている間に届いても位置を置きます。最初の開始が届く前は、走っているものとして数えます (止めている間もクロックを流し続ける機材は、最初の開始が届くまで拍がずれて数えます。開始で 0 に戻ります)。UMP のグループは区別せず、システムリセットは拍を戻しません。`watch` で作り直した直後も、数えていた拍から続きます。

機材なしでも確かめられます。`createMIDI(messages:)` に渡す列に `.start`・`.clock`・`.stop`・`.continue`・`.songPosition(sixteenths:)` を書くと、同じ入れ物を通って同じフレームに同じ拍が出ます (`Codable` なので、書き出して読み戻せます)。参照スケッチ `midi-and-beat` が、開始の後に 1 フレーム 1 クロックを注入し、途中から 1 フレーム 2 クロックにして、拍ごとに背景が切り替わる間隔がテンポについてくる様子を示します。クロックを送ること (出力) はまだありません。

**破壊的変更**: `MIDIMessage` に `clock`・`start`・`stop`・`continue`・`songPosition(sixteenths:)` の 5 つの場合を足したため、`port.messages` の要素を `switch` で**網羅して**書いていると組めなくなります。`default:` を足してください (`case .controlChange: break` で終えていた例は `default: break` に直します)。クロックは 120 BPM で毎秒 48 個届くので `messages` には入らず、拍を進めるだけです。開始・停止・再開・曲の位置は、拍を動かしたうえで `messages` に届いた順に入ります。拍だけが要るなら `messages` は読まなくてかまいません。
