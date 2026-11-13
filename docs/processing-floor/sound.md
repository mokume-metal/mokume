<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Sound

Processing Sound のリファレンスのうち、25 のクラスのページと、そのメソッド 140 の計 165 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。PR [#2221] の本文にだけあった Sound の対応表は、この表へ取り込んだ ([#3133] の決定 Q6)。#2221 より後に入った API (`isBeat`・`waveform`・`energy(from:to:)`・`position`・`duration`・`jump(_:)`・`SoundFile` をエフェクトに通す API・`play(at:)`) は、いまの main に合わせた。

| 区分 | 件数 |
| --- | --- |
| 同等 | 114 |
| 入れる | 4 |
| 作例待ち | 36 |
| 持たない | 11 |
| 計 | 165 |

この領域に共通すること:

- **作る API は `create` + 型の名前** (`createSinOsc()`・`createLowPass()`・`createAudioIn()`)。`new SinOsc(this)` は持たない ([#1980]・PR [#2221])。`SoundFile` は `loadSound(_:)` と、`Task` の中から読み込む `requestSound(_:)` で作る。投げるのは作るときだけで、鳴らす・止める API は投げない
- **範囲外の値は範囲内に収め、数値でない値は無視する。どちらも 1 度だけ警告する** (投げない — [ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 5)
- **解析の値は、解析器を `input()` で接続する形ではなく、音源が持つ** ([ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 6 の改訂 (2026-10-23)・[#2463] が `FFT`・`Amplitude`・`BeatDetector`・`Waveform` を解析器にする案を退けた)。`AudioIn`・`SoundFile`・`SynthSound` (合成した音とエフェクト) が同じ名前で `rms`・`decibels`・`peak`・`spectrum`・`level`・`spectrumLevels`・`energy(from:to:)`・`waveform`・`isBeat` を持つ。下の「解析」の節で `Amplitude`・`FFT`・`BeatDetector`・`Waveform` を同等とするのはこのため (値を受け取る側が音源に移った形。[#3137] が `BeatDetector`・`Waveform` を同等と決め、2026-11-03 の決定で `Amplitude`・`FFT` も揃えた)
- **エフェクトに通せるのは、合成した音と `SoundFile`** (`EffectInput`・[#2220]・PR [#3109])。`AudioIn` (マイク) は通せない。エフェクトの出力を別のエフェクトの入力にもできる (Processing に無い拡張)
- **合成した音は 1 つのスケッチで 64 個まで** (オシレータ・ノイズ・エフェクトの合計。エフェクトに通した `SoundFile` も 1 つずつ数える)。音量の既定は合成した音が 0.5、`SoundFile` が 1
- **mokume にだけある API**: `add(_:)` (波形を上下にずらす)、先の時刻に再生を予約する `play(at:)` と `Env.play(…, at:)`・音の時計を読む `Sketch.soundTime` (PR [#3517])、鳴らさずに解析だけする `createAudioIn(file:)`・`createAudioIn(samples:sampleRate:)`。リファレンスに無いので数えない
- **引数の位置がリファレンスと食い違う形がある。** リファレンスの `noise.play(amp, pos)`・`noise.set(amp, pos)` の第 2 引数と、`osc.set(freq, amp, pos)` の第 3 引数は定位 (`pos`) だが、mokume の同じ位置は `add` である (定位は後ろ)。`delay.process(input, maxDelayTime, delayTime)` の第 3 引数は遅延時間で、mokume ではフィードバックの割合 (`feedback`) である。該当する行の理由に「違い」として書いた。リファレンスの引数をそのまま移すと、定位が加算値に、遅延時間がフィードバックの割合になる

## 「入れる」の API をまとめた Feature

「入れる」に選んだ 15 件は、近い API ごとに 4 つの Feature で入れる。うち 1 つ (#3473) は、表より前から Issue がある。入れ終えた Feature は「入れた」と書き、その API の行は節の表で「同等」に直した (上の件数は直した後の数)。

| Feature | API | 件数 |
| --- | --- | --- |
| [#3473] `SoundFile` の再生速度と定位 (既存の Issue。意味は決定済みで、型を `Feature` に替えてラベルを付ければ着手できる。`pan` と `rate` は別の PR でよい。`SoundFile.pan()` は入れた。区分は `rate` を入れてから 4 件まとめて直す) | `SoundFile.rate()`・`pan()`・`AudioSample.rate()`・`pan()` | 4 |
| [#3705] `SoundFile` のチャンネルの数とサンプルの数 (入れた。`SoundFile` の 2 件は「SoundFile と AudioSample」の節で同等、`AudioSample` の 2 件は型が無いので作例待ちに揃えた) | `SoundFile.channels()`・`frames()`・`AudioSample.channels()`・`frames()` | 4 |
| [#3706] `BandPass` を Q で決める (入れた。行は「エフェクト」の節で同等) | `BandPass.res()` | 1 |
| [#3718] `BrownNoise` (入れた。行は「ノイズ」の節で同等) | `BrownNoise` (クラス)・`amp()`・`pan()`・`play()`・`set()`・`stop()` | 6 |

件数に入らない行が 1 つある。`Env.play()` が `SoundFile` を受ける形は、`Env.play()` (同等) の「無い形」で、リファレンスの項目ではないので件数に数えず、「Env」の節に子の行として置いた。これも「入れる」で、Feature は既存の [#3099] (入れた。子の行は「同等」に直した)。

## オシレータ

28 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc` (クラス 4 件) | `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc` (`Sketch.createSinOsc()`・`createSqrOsc()`・`createTriOsc()`・`createSawOsc()` が作る。基底は `Oscillator`・`SynthSource`) | 同等 | 型の名前は Processing のまま。矩形波とのこぎり波は、高次の倍音が折り返して濁らないよう角を丸めてある。作る API は `new SinOsc(this)` ではなく `createSinOsc()` | [#1980]・PR [#2221] |
| `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc` の `amp()`・`pan()`・`stop()` (4 クラス × 3 = 12 件) | `SynthSource.amp(_:)`・`pan(_:)`・`stop()` | 同等 | `amp` は 0〜1、`pan` は -1〜1 (左右の合計のパワーが変わらない定位で、中央は左右とも 1/√2)。`stop()` は約 5 ミリ秒かけてフェードアウトし、`play()` で鳴らし直せる。エフェクトを通した音の定位は、エフェクトの出力では中央になる | PR [#2221] |
| `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc` の `freq()` (4 件) | `Oscillator.freq(_:)` | 同等 | 0 からサンプルレートの半分 (24000 Hz) まで。無い形: 別のオシレータを渡して周波数変調する `freq(modulator)` | PR [#2221] |
| `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc` の `play()` (4 件) | `SynthSource.play()`・`Oscillator.play(_:_:_:_:)` | 同等 | 引数なしは現在の設定のまま (止めた後なら位相を先頭から)。`play(freq, amp, add, pos)` の `pos` は `pan`。mokume にだけ、先の時刻に再生を予約する `play(at:)` がある | PR [#2221]・[#3517] |
| `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc` の `set()` (4 件) | `Oscillator.set(_:_:_:_:)` | 同等 | 鳴らさずに周波数・音量・加算値・定位を決める。**違い:** リファレンスの `set(freq, amp, pos)` (3 引数) の第 3 引数は定位だが、mokume の第 3 引数は `add` で、定位は 4 つ目。`set(440, 0.5, -1)` と移すと左に定位せず、波形が -1 ずれる | PR [#2221] |

## ノイズ

18 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `WhiteNoise`・`PinkNoise` (クラス 2 件) | `WhiteNoise`・`PinkNoise` (`Sketch.createWhiteNoise()`・`createPinkNoise()` が作る。基底は `Noise`・`SynthSource`) | 同等 | ノイズの系列は固定で、同じ順に作れば何度鳴らしても書き出しても同じ音になる (シードを選ぶ API は持たない) | [#1980]・PR [#2221] |
| `BrownNoise` (クラス) | `BrownNoise` (`Sketch.createBrownNoise()` が作る。基底は `Noise`・`SynthSource`) | 同等 | ホワイトノイズをリーキー積分器 (カットオフ 約 150 Hz) に通す。カットオフより上は 1 オクターブごとに 6 dB 下がり、下は平坦なので直流成分が溜まらない。サンプル値は -1〜1。系列は `WhiteNoise`・`PinkNoise` と同じく固定のシードで固定する | [#3718]・[#3684 のコメント](https://github.com/mokume-metal/mokume/issues/3684#issuecomment-6586701566) |
| `WhiteNoise`・`PinkNoise`・`BrownNoise` の `amp()`・`pan()`・`stop()` (3 クラス × 3 = 9 件) | `SynthSource.amp(_:)`・`pan(_:)`・`stop()` | 同等 | オシレータの同じ名前の API と同じ | PR [#2221]・[#3718] |
| `WhiteNoise`・`PinkNoise`・`BrownNoise` の `play()`・`set()` (3 クラス × 2 = 6 件) | `Noise.play(_:_:_:)`・`Noise.set(_:_:_:)` | 同等 | 音量・加算値・定位を決めて鳴らす (`set` は鳴らさない)。`play(amp, add, pos)` の形はリファレンスと同じ。**違い:** リファレンスの `play(amp, pos)`・`set(amp, pos)` (2 引数) の第 2 引数は定位だが、mokume の第 2 引数は `add` で、定位は 3 つ目 | PR [#2221]・[#3718] |

## 見送った音源とエフェクト

12 件。PR [#2221] が「Issue ([#1980]) の範囲外・作例に要らない」として作らなかった 3 つ。`Pulse` と `AllPass` は選択が分かれる点があるので、見送りを引き継いで作例待ちとした。`BrownNoise` は選択が分かれる点が無いので、2026-11-03 の決定 ([#3684 のコメント](https://github.com/mokume-metal/mokume/issues/3684#issuecomment-6586701566)) で選び直して入れ ([#3718])、行は「ノイズ」の節へ移した。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Pulse` (クラス)・`amp()`・`freq()`・`pan()`・`play()`・`set()`・`stop()`・`width()` (8 件) | — | 作例待ち | #2221 は作らなかった (範囲外・作例に要らない)。選択が分かれる点: パルス幅 (`width`) を持つ別の型にするか、`SqrOsc` に幅を追加するか。`Pulse.set(freq, width, amp, add, pos)` は引数が 5 つで、`Oscillator.set(_:_:_:_:)` の形とも違う | [#1980]・PR [#2221] |
| `AllPass` (クラス)・`gain()`・`process()`・`stop()` (4 件) | — | 作例待ち | #2221 は作らなかった (範囲外・作例に要らない)。選択が分かれる点: リファレンスの `AllPass` は `gain` だけを持ち、遅延時間の長さを持たない。位相の変え方 (段数・遅延時間) を mokume の側で選ぶ必要がある。`Reverb` の中のオールパスフィルタとは別の API になる | [#1980]・PR [#2221] |

## Env

2 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Env` (クラス) | `Env` (`Sketch.createEnv()` が作る) | 同等 | ASR (台形) のエンベロープ。Processing と同じで、ADSR にはしない | [#1980]・PR [#2221] |
| `Env.play()` | `Env.play(_:_:_:_:_:)`・`play(_:_:_:_:_:at:)` | 同等 | 音源 (`SynthSource`) と `SoundFile` にエンベロープの形を掛ける (下の子の行)。エンベロープが終わると音源の音は 0 のまま、次に `env.play` を呼ぶまで無音。音源の音量にさらに掛かる。エフェクトの出力には掛けられない (Processing の `Effect` も `SoundObject` を継承せず、掛けられない)。mokume にだけ、合成した音源を先の時刻から始める `at:` がある | [#1980]・PR [#2221]・[#3517] |
| └ `Env.play()` のうち `SoundFile` を受ける形 (子の行・件数に数えない) | `Env.play(_:_:_:_:_:)` の `SoundFile` を受ける多重定義 | 同等 | 曲の冒頭のフェードイン・終わりのフェードアウトが `amp(_:)` を毎フレーム動かさずに書ける。Processing と同じく、再生中なら位置を動かさず、再生していなければ `play()` と同じ位置から鳴らし、エンベロープが終わっても再生は止めない。エンベロープは再生したサンプルの数で進む (一時停止の間は止まる)。`at:` の形は無い。エフェクトの出力と `AudioIn` は受けない | [#3099] |

## エフェクト

32 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `LowPass`・`HighPass` (クラス 2 件) | `LowPass`・`HighPass` (`Sketch.createLowPass()`・`createHighPass()` が作る。基底は `Filter`・`SoundEffect`) | 同等 | 既定はカットオフ 1000 Hz・Q 1 | [#1980]・PR [#2221] |
| `LowPass`・`HighPass` の `freq()`・`res()`・`set()`・`stop()` (2 クラス × 4 = 8 件) | `Filter.freq(_:)`・`res(_:)`・`set(_:_:)`・`SoundEffect.stop()` | 同等 | `freq` は 10〜20000 Hz、`res` (Q) は 0.1〜100。`stop()` は通していた音をエフェクトを通さない状態へ戻し、余韻は残さない | PR [#2221] |
| `LowPass`・`HighPass` の `process()` (2 件) | `SoundEffect.process(_:)`・`Filter.process(_:_:)`・`process(_:_:_:)` | 同等 | 入力は合成した音と `SoundFile`。`SoundFile` を通すと、最初に通したときからエフェクト経由で鳴る (左右はミックスされて中央のモノラルになる)。無い形: `AudioIn` (マイク) を通す形 (「AudioIn」の節) | PR [#2221]・[#3109] |
| `BandPass` (クラス) | `BandPass` (`Sketch.createBandPass()` が作る。基底は `SoundEffect`) | 同等 | 既定は中心周波数 1000 Hz・幅 500 Hz | [#1980]・PR [#2221] |
| `BandPass` の `bw()`・`freq()`・`process()`・`res()`・`set()`・`stop()` (6 件) | `BandPass.bw(_:)`・`freq(_:)`・`process(_:_:_:)`・`res(_:)`・`set(_:_:)`・`SoundEffect.stop()` | 同等 | `bw` は Hz の幅で、中心が動いても保たれる。`res` は Q (0.1〜10。リファレンスどおりで、`Filter.res(_:)` の 0.1〜100 とは違う) を保ち、幅は中心に比例して変わる。`bw` と `res` は後に呼んだほうが優先される (`set`・`process` の幅は `bw` と同じ)。入力の制限は `LowPass` と同じ | PR [#2221]・[#3109]・[#3706] |
| `Reverb` (クラス)・`damp()`・`process()`・`room()`・`set()`・`stop()`・`wet()` (7 件) | `Reverb`・`Reverb.damp(_:)`・`room(_:)`・`wet(_:)`・`set(_:_:_:)`・`process(_:_:_:_:)`・`SoundEffect.process(_:)`・`stop()` (`Sketch.createReverb()` が作る) | 同等 | Freeverb と同じ並べ方 (8 本のコムフィルタの後に 4 本のオールパスフィルタ)。既定は 3 つとも 0.5。`wet` 0 で通した音がそのまま出る | [#1980]・PR [#2221]・[#3109] |
| `Delay` (クラス)・`feedback()`・`set()`・`stop()`・`time()` (5 件) | `Delay`・`Delay.feedback(_:)`・`time(_:)`・`set(_:_:)`・`SoundEffect.stop()` (`Sketch.createDelay()` が作る) | 同等 | 遅延時間は最大 5 秒。既定は遅延時間 0.25 秒・フィードバックの割合 0.5。遅延時間を動かしている最中は音の高さが揺れる | [#1980]・PR [#2221] |
| `Delay.process()` | `Delay.process(_:_:)`・`process(_:_:_:)` | 同等 | **違い:** リファレンスの `process(input, maxDelayTime, delayTime)` の第 3 引数は初期の遅延時間だが、mokume の第 3 引数はフィードバックの割合 (`feedback`) で、遅延時間は `time(_:)` で決める。遅延時間の上限は 0〜5 秒の範囲外を範囲内に収める | PR [#2221]・[#3109] |

## 解析

17 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Amplitude` (クラス)・`analyze()`・`input()` (3 件) | `AudioIn`・`SoundFile`・`SynthSound` の `rms`・`level` | 同等 | 解析器を作らず、音源が値を持つ。`rms` は区間の二乗平均平方根 (振幅の単位。フルスケールの正弦波で約 0.707)、`level` は音の大きさを 0〜1 に正規化したもの (-60 dBFS が 0、0 dBFS が 1)。区間は前のフレーム以後の全サンプル。`input()` で接続する手間は無い | [#2463]・PR [#3265] |
| `FFT` (クラス)・`analyze()`・`input()` (3 件) | `AudioIn`・`SoundFile`・`SynthSound` の `spectrum`・`spectrumLevels` | 同等 | 帯域の数は 512 で固定 (フルスケールの正弦波が帯域の中心で 1)。`spectrumLevels` は同じ帯域を 0〜1 にしたもの。帯域 `k` の中心周波数は `k × sampleRate ÷ 1024` Hz。無い形: 帯域の数を選ぶ `new FFT(this, bands)`、配列へ書き込ませる `analyze(target)` | [#2463]・PR [#3265] |
| `FFT.analyzeSample()` | — | 作例待ち | 音のストリームによらず、手元のサンプル (配列) から 1 回だけスペクトルを求める API。`createAudioIn(samples:sampleRate:)` は時間に沿ってフレームごとに解析する API で、同じ働きではない。選択が分かれる点: 入力 (サンプルの配列か `SoundFile` か)、帯域の数を引数で取るか (いまは 512 固定)、左右を別々に呼ぶ形 | — |
| `BeatDetector` (クラス)・`input()`・`isBeat()` (3 件) | `AudioIn`・`SoundFile`・`SynthSound` の `isBeat` | 同等 | 区間にビートが 1 つ以上あれば `true` (複数あっても 1 回にまとめる)。判定は固定の 512 サンプル単位の順にだけ進み、fps や届く単位が違っても同じサンプル位置でビートが出る。名前は ADR-0020 決定 1 の改訂の規則 3 により Swift の慣行に合わせた | [#3137]・PR [#3269] |
| `BeatDetector.sensitivity()` | — | 作例待ち | 感度の API は持たない ([#3137] が作例待ちとした)。リファレンスの引数はビートとビートの間の最小の間隔 (ミリ秒) で、mokume の判定は固定の定数 (ビートの直後の 6 ブロック ≒ 64 ミリ秒を数えず、直近 94 ブロックの平均の 1.5 倍を超えたもの) を持つ。値を持たせて変更できるようにすると、判定の状態が引数に依存し、fps によらず同じ位置でビートを出す仕様 (水準 2) の範囲を決め直すことになる | [#3137]・PR [#3269] |
| `Waveform` (クラス)・`analyze()`・`input()` (3 件) | `AudioIn`・`SoundFile`・`SynthSound` の `waveform` | 同等 | 区間の終わりの 1024 サンプル (古い順)。チャンネルを平均した、音量を掛けた後のサンプル。何も鳴らなければ 1024 個の 0。無い形: サンプルの数を選ぶ `new Waveform(this, nsamples)` | [#3137]・PR [#3269] |
| `PitchDetector` (クラス)・`analyze()`・`input()` (3 件) | — | 作例待ち | 基本周波数を Hz で返す。選択が分かれる点: 信頼度の下限を作成時に持つか呼び出し時に渡すか (リファレンスは両方)、基本周波数が無いときの値 (リファレンスは 0)、検出できる範囲、履歴を持つ状態を固定のホップ単位で進める作り (`isBeat` と同じ。fps に依らず同じサンプル位置で出す仕様を守るため) | — |

## AudioIn

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `AudioIn` (クラス)・`stop()` (2 件) | `AudioIn` (`Sketch.createAudioIn(device:)` が作る)・`AudioIn.stop()` | 同等 | マイクの音を解析する入り口。許可は OS が求め、デバイスが無くても作れる。利用者が止めたものは、取り付け直しても止まったまま (受け始めるには新しく作る)。無い形: 入力チャンネルの番号を渡す `new AudioIn(this, in)` (mokume はデバイス (`AudioDevice`) で選ぶ) | PR [#2160] |
| `AudioIn.start()` | `Sketch.createAudioIn(device:)` | 持たない | 作ると同時にデバイスを開き、許可を待つ。リファレンスの `start()` は「出力へ流さずに入力を始める」API で、mokume の `AudioIn` は出力へ流さないので、作ることがそれに当たる。止めた後に始め直す API は持たない | PR [#2160] |
| `AudioIn.amp()`・`pan()`・`play()`・`set()` (4 件) | — | 作例待ち | マイクの音を出力へ流す API (`play()`) と、流す音の音量・定位 (`amp`・`pan`・`set`)。mokume の `AudioIn` は解析の対象に取り付けるだけで、出力へ流す API が無い ([#2220] が範囲外とした。エフェクトに通せないことも同じ根本原因)。選択が分かれる点: マイクの音を鳴らす新しい振る舞いを足すこと (ハウリング・入力の遅延・許可) をどこまで標準にするか | [#2220] |

## SoundFile と AudioSample

38 件。Processing では `SoundFile` が `AudioSample` を継承し、リファレンスは同じ名前の API を両方に載せる (`play()`・`jump()` ほか 12 組)。組は 1 行にまとめ、mokume の API は `SoundFile` のものを挙げる。mokume にはサンプルの配列から作る型が無く、`AudioSample` の API で `SoundFile` に当てはまるものだけが行を持つ。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `SoundFile` (クラス) | `SoundFile` (`Sketch.loadSound(_:)`・`requestSound(_:)` が作る) | 同等 | 読み込みは作るときに 1 度だけで、鳴らしながら解析の値が読める。無い形: 復号したサンプルを RAM に残すかを選ぶ `new SoundFile(this, path, cache)` の `cache` (mokume は残すキャッシュを持たない。`removeFromCache()` の行) | PR [#2200] |
| `AudioSample` (クラス) | — | 作例待ち | サンプルの配列から作って再生する型。mokume の `SoundFile` は読み込んだサンプルを作成後に書き換えられない (`let`) ので、同じ型に追加するのではなく、別の型にするか、作る API を追加するか、作成後に書き換える `write()`・`resize()` (下の行) まで持つかの選択が分かれる。ファイルから読む `SoundFile` は同等 | — |
| `SoundFile`・`AudioSample` の `amp()` (2 件) | `SoundFile.amp(_:)` | 同等 | 0〜1 (既定 1)。解析の値も、この音量を掛けた音のものになる | PR [#2200] |
| `SoundFile`・`AudioSample` の `duration()` (2 件) | `SoundFile.duration` | 同等 | プロパティで、単位は秒 (`Float`)。`Movie.duration` と揃えた | [#2464]・PR [#2864] |
| `SoundFile`・`AudioSample` の `loop()`・`pause()`・`play()` (3 つ × 2 = 6 件) | `SoundFile.loop()`・`pause()`・`play()` | 同等 | `pause()` は一時停止して位置を記憶し、次の `play()`・`loop()` はそこから鳴らす。`stop()` と再生が終わった後 (終わりへ `jump` した後も) は先頭から ([#3303])。**違い:** 鳴っている最中に `play()`・`loop()` を呼ぶと先頭から鳴らし直す (リファレンスの `AudioSample` は重ねて鳴らせる)。無い形: 引数つきの `play(rate, pos, amp, add, cue)`・`loop(rate, pos, amp, add)` (再生速度と定位は `rate(_:)`・`pan(_:)` を呼んでから鳴らす。`add` は無い) | PR [#2200]・[#3303] |
| `SoundFile`・`AudioSample` の `jump()` (2 件) | `SoundFile.jump(_:)` | 同等 | 秒で指定して移動する。呼んだ直後から `position` は移動先を返す。0 より前は先頭、`duration` より後は終わりに収め、数値でない値は位置を変えず 1 度だけ警告する。**違い:** リファレンスの `jump()` は止まっているときに鳴らし始めるが、mokume は止まっている間は位置だけを動かし、鳴らさない (次の `play()`・`loop()` がそこから鳴らす) | [#2464]・PR [#2864] |
| `AudioSample.position()` | `SoundFile.position` | 同等 | プロパティで、現在の再生位置 (秒)。リファレンスでは `AudioSample` にだけ載る (`SoundFile` が継承する) | [#2464]・PR [#2864] |
| `AudioSample.sampleRate()` | `SoundFile.sampleRate` | 同等 | ファイルのサンプルレート (Hz)。設定はできない | PR [#2200] |
| `AudioSample.stop()` | `SoundFile.stop()` | 同等 | 止めて先頭へ戻す | PR [#2200] |
| `SoundFile.isPlaying()` | `SoundFile.isPlaying` | 同等 | プロパティ。値はそのフレームの開始時点のもの | PR [#2200] |
| `SoundFile`・`AudioSample` の `rate()`・`pan()` (2 つ × 2 = 4 件) | `SoundFile.pan(_:)` (定位だけ入れた) | 入れる | 定位: 合成音の `pan(_:)` と同じ API の形 (-1〜1・範囲の外は端へ丸め・数でない値は無視) で、基準の大きさは違う。モノラルは中央で左右とも 1 倍の、左右を合わせた大きさが変わらない定位 (端で片側が √2 倍。合成音は中央 1/√2)、ステレオは反対側だけを下げる直線のバランス、3 チャンネル以上は先頭の 2 チャンネルだけ。解析は定位を掛ける前の音で、エフェクトに通したファイルはエフェクトの出口で中央。再生速度 (リサンプリングでピッチも変わる) の意味も [#3473] の本文で決まっている (0 以上・位置はファイルの秒のまま・解析は鳴った音)。実装は 4 つの進め方 (固定の時計のフレーム・実時間・直接鳴らす経路・エフェクトを通した経路) すべてに入れる。基準 2〜5 を満たす (リサンプリングは AVFAudio だけで書ける) | [#3473]・[#2464] |
| `SoundFile.channels()`・`frames()` (2 件) | `SoundFile.channels`・`SoundFile.frames` | 同等 | チャンネルの数とサンプルの数を読むプロパティ。`channels` は 3 チャンネル以上でも 2 に減らさず数をそのまま返す (解析の値はチャンネルを平均したものだが、この数は平均する前)。`frames` は読み込んだサンプルの数そのもので、`duration * sampleRate` の近似ではない (単精度の丸め誤差で長いファイルのサンプルの数が合わない)。取り外した後も取り付け直した後も同じ値 | [#3705]・[#3969] |
| `AudioSample.channels()`・`frames()` (2 件) | — | 作例待ち | 読み取りの意味は `SoundFile` の行と同じだが、`AudioSample` の型が無い (上の `AudioSample` (クラス) の行が作例待ち)。型を追加するときに、`SoundFile` と同じプロパティを持たせる | [#3705] |
| `SoundFile`・`AudioSample` の `cue()` (2 件) | `SoundFile.jump(_:)` (止まっている間) | 持たない | 止まっている間の `jump(_:)` が、次の `play()` の位置を決める。リファレンスの `cue()` は `play()` の位置にだけ効き `loop()` には効かないが、mokume の位置は両方に効く | [#2464] |
| `AudioSample.percent()` | `song.position / song.duration` | 持たない | 割り算 1 つで求められ、百分率にするかは作者が決める | — |
| `AudioSample.set()` | `rate(_:)`・`pan(_:)`・`amp(_:)` | 持たない | 再生速度・定位・音量を続けて呼ぶ (`rate`・`pan` は [#3473] で入れる)。3 つをまとめる API は足さない | — |
| `SoundFile.removeFromCache()` | — (手放せば解放される) | 持たない | 読み込んだサンプルを共有するキャッシュが無い。`loadSound(_:)` は呼ぶたびに読み込み、`SoundFile` への参照を手放せばサンプルも解放される | — |
| `AudioSample.positionFrame()`・`jumpFrame()`・`cueFrame()` (3 件) | — | 作例待ち | サンプルの番号で位置を指す API。位置は秒の `Float` で持つ ([#2464] が `Movie` に揃えた) ので、長いファイル (約 350 秒 = 2^24 サンプルより長い) では秒からサンプルの番号が合わない。選択が分かれる点: 番号の API を秒の API と別に持つか、位置をサンプルの整数で持ち直すか。`cue` を持たないので `cueFrame()` は `jumpFrame()` とセット | [#2464] |
| `AudioSample.playFor()` | — | 作例待ち | 再生時間を指定して鳴らし、終わりで止める API。止める時刻をサンプルの単位で揃えるには、再生の予約が要る。`SoundFile` の予約 (`play(at:)`) は [#3516] がこの表では決められないと自ら書いた論点で、この行は区分だけを持ち、予約の形は決めない | [#3516] |
| `AudioSample.read()`・`write()`・`resize()` (3 件) | — | 作例待ち | サンプルを読み書きし、長さを変える API。上の `AudioSample` (クラス) とセットで選択が分かれる (書き換えられる型にするか)。`read()` はサンプルの並び (チャンネルを交互に並べるか、チャンネルごとか) と、読む範囲を指定する引数の形がリファレンスに 4 通りある | — |

## Sound と MultiChannel

11 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Sound` (クラス) | `Sketch` の API (`audioInputDevices()` ほか) と、音ごとの API | 持たない | 音全体の設定をまとめる静的な名前空間で、インスタンスを作って使う型ではない。設定ごとの行は下 | — |
| `Sound.list()` | `Sketch.audioInputDevices()` | 同等 | 接続されている入力デバイスの一覧 (`AudioDevice` の `id` と `name`)。デバイスは抜き差しに追随し、一覧の位置では選ばない ([ADR-0028](../decisions/0028-external-inputs.md) 決定 3)。無い形: 出力のデバイス (一覧に出ない)、名前で絞り込む `list(filter)`、一覧を出力する `list(printAll)` | PR [#2160] |
| `Sound.inputDevice()` | `Sketch.createAudioIn(device:)` | 持たない | 入力デバイスは、全体の設定ではなく、`AudioIn` を作るときに選ぶ。デバイスを指すのは一覧から得た識別子 | PR [#2160] |
| `Sound.outputDevice()` | — | 作例待ち | 出力は既定の出力のデバイスで、選ぶ API は作らなかった (PR [#2221] の判断)。選択が分かれる点: 音声の出力経路はいま 1 つを共有するので、デバイスを選ぶのが全体か音ごとか。選ぶ形は ADR-0028 決定 3 (一覧・識別子・抜き差しへの追随) に従い、出力デバイスの一覧が先に要る | PR [#2221] |
| `Sound.sampleRate()` | `SoundFile.sampleRate`・`AudioIn.sampleRate`・`SynthSound.sampleRate` (読むだけ) | 持たない | 合成のサンプルレートは 48000 Hz で固定する (書き出しでも同じ。決定論のため)。読む API は音ごとにある。変える API は持たない | PR [#2221] |
| `Sound.status()` | — | 持たない | 合成エンジンの負荷の表示。mokume の音は AVAudioEngine で、対応する値が無い。上限は冒頭の共通事項にある 64 個で、超えると 1 度だけ警告する | — |
| `Sound.volume()` | — | 作例待ち | 全体の音量。選択が分かれる点: API の名前 (静的な `Sound.volume` に当たる `Sketch` の API の名前)、書き出しの音声トラックに入る音にも掛けるか、解析の値 (音源の出力で測る) には掛けないか | — |
| `MultiChannel` (クラス)・`activeChannel()`・`availableChannels()` (3 件) | — | 作例待ち | 2 チャンネルより多い出力デバイスへの振り分け。mokume の音は左右の定位 (`pan`) だけ。出力のデバイスを選ぶ API (`Sound.outputDevice()`) とセットで選択が分かれる: チャンネルの番号を音ごとに持つか、定位の延長で振り分けるか | — |
| `MultiChannel.usePortAudio()` | — | 持たない | 音声出力の方式 (JavaSound と PortAudio) を切り替える API。macOS の mokume は AVAudioEngine だけで、切り替える仕組みが無い | — |

[#1980]: https://github.com/mokume-metal/mokume/issues/1980
[#2160]: https://github.com/mokume-metal/mokume/pull/2160
[#2200]: https://github.com/mokume-metal/mokume/pull/2200
[#2220]: https://github.com/mokume-metal/mokume/issues/2220
[#2221]: https://github.com/mokume-metal/mokume/pull/2221
[#2463]: https://github.com/mokume-metal/mokume/issues/2463
[#2464]: https://github.com/mokume-metal/mokume/issues/2464
[#2864]: https://github.com/mokume-metal/mokume/pull/2864
[#3099]: https://github.com/mokume-metal/mokume/issues/3099
[#3109]: https://github.com/mokume-metal/mokume/pull/3109
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3137]: https://github.com/mokume-metal/mokume/issues/3137
[#3265]: https://github.com/mokume-metal/mokume/pull/3265
[#3269]: https://github.com/mokume-metal/mokume/pull/3269
[#3303]: https://github.com/mokume-metal/mokume/issues/3303
[#3473]: https://github.com/mokume-metal/mokume/issues/3473
[#3516]: https://github.com/mokume-metal/mokume/issues/3516
[#3517]: https://github.com/mokume-metal/mokume/pull/3517
[#3705]: https://github.com/mokume-metal/mokume/issues/3705
[#3706]: https://github.com/mokume-metal/mokume/issues/3706
[#3718]: https://github.com/mokume-metal/mokume/issues/3718
[#3969]: https://github.com/mokume-metal/mokume/issues/3969
