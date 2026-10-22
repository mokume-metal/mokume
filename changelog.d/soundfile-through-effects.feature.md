<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音声ファイル (`SoundFile`) を、合成した音と同じエフェクト (`LowPass`・`HighPass`・`BandPass`・`Reverb`・`Delay`) に通せるようにした。`filter.process(song, 800)` のように、`process` が受けるのは合成した音だけでなく `SoundFile` にもなり、曲にフィルタやリバーブを掛けた絵と音の作品が、曲を合成し直さずに書ける。`process` の引数の型は、`SynthSound` と `SoundFile` が準拠する新しい protocol `EffectInput` になった (Processing Sound の `SoundObject` に当たる。マイクの `AudioIn` は通せない)。

通した `SoundFile` は、エフェクトの出口を通ってだけ聞こえる。通すまでは今までどおり直に鳴り、鳴っている最中に通しても頭へ戻らず、`play()`・`loop()`・`pause()`・`stop()`・`jump(_:)`・`amp(_:)` と `position`・解析の値は通さないときと同じに効く。書き出し (固定の時計) では鳴らさずに、同じ設定から同じ出口の値を取れる。

代償が 3 つある。エフェクトの出口は中央なので、左右のある曲もモノラルになる。通した `SoundFile` は合成した音と同じ節の上限 (64) を 1 つ使い、埋まっていれば通さず 1 度だけ知らせる。標本化率がラックの 48000 Hz (書き出しではその率) と違う曲は、通すとラックの率へ読み直される。
