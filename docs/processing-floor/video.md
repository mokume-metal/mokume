<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Video

Processing Video の参照のうち、`Movie` と `Capture` の 2 つのクラス (クラスの頁とメソッド)、それぞれのイベント関数 (`movieEvent()`・`captureEvent()`) の 21 件。形・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-03)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 13 |
| 入れる | 0 |
| 作例待ち | 2 |
| 持たない | 6 |
| 計 | 21 |

この領域に共通すること:

- **映ったコマは `image` に入り、普通の `Image` として描く。** Processing の `Movie`・`Capture` は `PImage` なので `image(movie, 0, 0)` と書くが、mokume は `image(clip.image, 0, 0)`。毎フレーム呼ぶ API は無く、`draw()` の前にそのフレームのコマが `image` へ書かれている ([ADR-0028](../decisions/0028-external-inputs.md) 決定 5・[ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 1)。新しいコマかは `isNewFrame` で見る
- **作る API は `Sketch` の関数で、`setup()`・`draw()`・入力のコールバックの中で呼ぶ。** `new Movie(this, …)` は `createVideo(_:)`、`new Capture(this, …)` は `createCapture(…)`。外で呼ぶと、動画は `MovieFailure.notRunning` を投げ、カメラは `ImageFailure.notRunning` を投げる
- **動画の位置はスケッチの時刻で決まる。** 実時間の再生時計を持たないので、固定の時計で書き出すと、同じフレーム番号にはいつも同じコマが出る ([ADR-0028](../decisions/0028-external-inputs.md) 決定 7)。`pauseTime()` でスケッチの時刻を止めれば動画も止まる
- **動画は音を鳴らさない。** 下の `Movie.volume()` の注を見る
- **動画の名前はファイルだけを受ける** (探す場所は `loadImage(_:)` と同じ)。Processing が受ける「ネットワーク上の場所」は、いまの mokume に無い (欠けた形)

## Movie

14 件。`Movie` の行のうち `Sources/MokumeCamera/Movie.swift` の表にある API は、その表を指す。表は利用者の面なので説明を写さない。ここで足すのは、その表に無い API の区分と、無い形である。表の場所は [`Movie` の「操作」の表][movie-table] (`Movie` の説明文の「操作」の節)。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Movie` (クラス) | `Movie`・`createVideo(_:)` | 同等 | 動画ファイルを流す入り口。見つからない・開けない・動画として読めないときは投げる (`MovieFailure`)。無い形: ネットワーク上の動画 (名前はファイルだけ) | — |
| `Movie.play()`・`loop()`・`pause()`・`jump()` (4 件) | `Movie.play()`・`loop()`・`pause()`・`jump(_:)` | 同等 | [`Movie` の「操作」の表][movie-table]の同名の行。`play()`・`loop()`・`jump(_:)` は次のフレームで効く | — |
| `Movie.speed()` | `Movie.speed(_:)` | 同等 | [`Movie` の「操作」の表][movie-table]の行。無い形: 負の速さ (逆再生)。`speed(-1)` は速さを変えず、1 度だけ知らせる | [#2451] |
| `Movie.time()`・`duration()` (2 件) | `Movie.time`・`Movie.duration` | 同等 | [`Movie` の「操作」の表][movie-table]の行。どちらも秒の `Float` のプロパティ | [#2451] |
| `Movie.available()` | `Movie.isNewFrame` | 同等 | [`Movie` の「操作」の表][movie-table]の `available()` / `read()` の行の前半。プロパティで、そのフレームに新しいコマが `image` へ書かれたかを返す。Processing は `read()` するまで `true` のままだが、`isNewFrame` は 1 フレームごとに決まる | — |
| `Movie.noLoop()` | `Movie.play()` (`loop()` で流している間に呼ぶ) | 同等 | `loop()` で流している間に `play()` を呼ぶと、今回の終わりで止まり、終わりのコマが残る。止まっている動画に `play()` を呼ぶと流し始める。`noLoop()` の名前の API は足さない (同じ働きの口があるので) | — |
| `Movie.read()` | — (`draw()` の前に `image` が書かれる) | 持たない | [`Movie` の「操作」の表][movie-table]の `available()` / `read()` の行の後半。読む API は要らず、`image` を描けばよい | — |
| `Movie.stop()` | `Movie.pause()` と `Movie.jump(0)` | 持たない | Processing の `stop()` は止めて頭へ戻す。mokume は止める (`pause()`) と頭へ飛ぶ (`jump(0)`) の 2 つの API で書く。`Movie.swift` の表に行は無い | — |
| `Movie.frameRate()` | — | 作例待ち | 「読む頻度を指定する」意味が割れる。(1) 映るコマを間引く (スケッチは 60 fps のまま、動画のコマを毎秒 4 枚しか替えない。見た目が変わる)、(2) 復号する頻度を下げる (映るコマの替わり方は変えず、負荷だけを下げる)。mokume は毎フレームのコマを位置で決めるので、どちらも API の形 (引数か、別の API か) から選ぶ必要がある。作例が来てから選ぶ | — |
| `movieEvent()` | — (`draw()` の中で `isNewFrame` を見る) | 持たない | 新しいコマが届いたときに呼ばれるコールバックで、Processing も「その中では描けない」と書く。mokume は OS の受け口のコールバックを利用者に漏らさず、コマは `draw()` の前に 1 回だけ取り出す ([ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 7) | — |

### 参照に載らない API (件数に数えない)

`Movie.volume()` は参照の JSON に項目が無い (Javadoc にだけある API は数えない・README の「版」)。ただし `Movie.swift` の表に行があるので、区分をここに写す。

- **`Movie.volume()` は持たない。** 同じファイルを `loadSound` で鳴らし、`jump` で映像の位置へ合わせる。`Movie` の音を `Movie` の位置に従わせる案 (#3452 の A) へ進む条件は、`MokumeCamera` と `MokumeAudio` の境を先に決めることである ([#3452]・PR [#3541]。[#3133] の 2026-10-30 のコメント)

## Capture

7 件。Processing の `Capture` はカメラの入力で、mokume の API は `MokumeCamera` にある。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Capture` (クラス) | `Capture`・`createCapture(_:_:device:mirrored:)` | 同等 | カメラの絵を受け取る入り口。大きさは引数で頼む (既定 640×480)。使うカメラは名前の文字でなく、`captureDevices()` が返す `CaptureDevice` で選ぶ (参照の説明に出る `Capture.list()` に当たる)。無い形: フレームレートを渡す形 `Capture(parent, width, height, fps)` ほか (下の `frameRate()`)。カメラが無くても作れ、`state` が理由を報告する (許可待ち・拒まれた・カメラが無い・抜かれた) | — |
| `Capture.available()` | `Capture.isNewFrame` | 同等 | `Movie.available()` と同じ。プロパティで、そのフレームに新しい絵が `image` へ書かれたか | — |
| `Capture.stop()` | `Capture.stop()` | 同等 | カメラを閉じ、以後 `image` は変わらない。**止めたものは足し直しても止まったまま**で、受け始めるには新しく作る (下の `start()`) | — |
| `Capture.read()` | — (`draw()` の前に `image` が書かれる) | 持たない | `Movie.read()` と同じ。読む API は要らず、`image` を描けばよい | — |
| `Capture.start()` | — (`createCapture(…)` が開く) | 持たない | 作った呼び出しがカメラを開くので、始める API は要らない。呼んだときだけ機材を開き、`import` しただけで点かない。止めたカメラを再び始める API も持たず、新しく作る | — |
| `Capture.frameRate()` | — | 作例待ち | カメラが出す頻度を頼む意味が割れる。(1) 機材のフレームレートを選ぶ (`CaptureDevice.formats` の `frameRates` に一覧はあるが、選ぶ API は無い。`createCapture` の引数か、`CaptureFormat` を渡す形か)、(2) 届いた絵を間引く (`Movie.frameRate()` と同じ)。どれを API にするかは作例が来てから選ぶ | — |
| `captureEvent()` | — (`draw()` の中で `isNewFrame` を見る) | 持たない | `movieEvent()` と同じ理由 ([ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 7) | — |

[movie-table]: ../../Sources/MokumeCamera/Movie.swift
[#2451]: https://github.com/mokume-metal/mokume/issues/2451
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3452]: https://github.com/mokume-metal/mokume/issues/3452
[#3541]: https://github.com/mokume-metal/mokume/pull/3541
