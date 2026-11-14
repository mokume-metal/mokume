<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

入力ソースの状態 `SourceState` に、用意している間を表す `.preparing` を足しました ([#3587](https://github.com/mokume-metal/mokume/issues/3587))。画像から手を探す `createHandPose(_:arrival:)` は、推論のモデルを読み込んでいる間 (この Mac で初めて使うときは数秒) `.preparing` を返し、描画は止めません。読み込みが済めば、手が写っていなくても `.running` になるので、「まだ推論できない」と「手が写っていない」を状態で見分けられます。観測の応答の `inputs[].state` にも `"preparing"` が載ります。

移行: `SourceState` のすべての case を `switch` で書き分けているスケッチは、`.preparing` の分岐が無いとコンパイルできなくなります。分岐を 1 つ足してください。

```swift
switch hands.state {
case .running: text("動いている", 10, 20)
case .preparing: text("準備中", 10, 20)  // 足す
case .waitingForPermission, .denied, .unavailable, .disconnected, .stopped: text("止まっている", 10, 20)
}
```

`default:` で受けている `switch` と、`==` で 1 つの状態だけを比べているコードは、書き換えなしで動きます。カメラ・マイク・MIDI などのこれまでの入力ソースは `.preparing` を返しません。
