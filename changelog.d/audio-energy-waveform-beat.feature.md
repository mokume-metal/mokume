<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音を解析する `AudioIn`・`SoundFile`・合成した音 (`SynthSound`) に、低音の脈動・拍・波形を自作せずに描ける 3 つの口を足しました: `energy(from:to:)` (周波数の範囲の大きさ)・`waveform` (区間の終わりの 1024 標本)・`isBeat` (そのフレームの区間に拍があったか) ([#3137](https://github.com/mokume-metal/mokume/issues/3137))。

```swift
func draw() {
    guard let song else { return }
    if song.isBeat { flash = 1 }
    flash *= 0.9
    background(30 + flash * 200, 30, 40)
    circle(width / 2, height / 2, 100 + song.energy(from: 20, to: 140) * 300)
}
```

- `energy(from:to:)` は 0〜1 の `Float`。範囲に中心が入る帯域の振幅の平均を、`level` と同じ dB の固定範囲 (-60 dBFS が 0、0 dBFS が 1) で写した値で、帯域の番号を自分で割り出さずに低音を取れる。逆順は入れ替え、はみ出す分は端へ寄せ、数でない値は 0 を返して 1 度だけ知らせる
- `isBeat` は、hop (512 標本) ごとのブロックのエネルギーが直近 1 秒の平均を急に上回ったところを拍にする。**判定は標本の順にだけ進む**ので、同じ標本列からは、fps や届くチャンクの長さが違っても同じ標本位置で拍が出る (ファイル・標本列・合成音は固定の時計の書き出しで同じ拍で光る。マイクは到着が実時間で決まるので除く)。履歴は音が鳴り始めたときから、読まなくても毎フレーム溜める (どのフレームから読み始めても同じ。費用は標本あたり二乗和 1 回)。飛ぶ・頭から鳴らし直すと履歴を捨てて始め直し、止めた位置から続けたり、ループで頭へ戻ったり、エフェクトへ通したりしても履歴は続く。`SoundFile` の拍は音量を掛けた後の標本で判定する (音量を動かすと拍が出る・消える)。約 7.8 fps より遅いと、区間の上限で履歴を捨て続け、拍は fps に依る。1 つの区間に拍が複数あっても `true` 1 回
- 参照スケッチ `beat-and-waveform` を足しました (低音で円が脈打ち、拍で背景が光り、下に波形が流れる)
