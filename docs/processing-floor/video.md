<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Video

Processing Video のリファレンスのうち、`Movie` と `Capture` の 2 つのクラス (クラスの頁とメソッド)、それぞれのイベント関数 (`movieEvent()`・`captureEvent()`) の 21 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-03)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 13 |
| 入れる | 0 |
| 作例待ち | 2 |
| 持たない | 6 |
| 計 | 21 |

この領域に共通すること:

- **映像のフレームは `image` に入り、通常の `Image` として描く。** Processing の `Movie`・`Capture` は `PImage` なので `image(movie, 0, 0)` と書くが、mokume は `image(clip.image, 0, 0)`。毎フレーム呼ぶ API は無く、`draw()` の前に、そのフレームの映像が `image` へ書き込まれている ([ADR-0028](../decisions/0028-external-inputs.md) 決定 5・[ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 1)。新しい映像フレームかどうかは `isNewFrame` で確認する
- **作る API は `Sketch` の関数で、`setup()`・`draw()`・入力のコールバックの中で呼ぶ。** `new Movie(this, …)` は `createVideo(_:)`、`new Capture(this, …)` は `createCapture(…)`。これらの外で呼ぶと、動画は `MovieFailure.notRunning` を投げ、カメラは `ImageFailure.notRunning` を投げる
- **動画の再生位置はスケッチの時刻で決まる。** 実時間の再生時計を持たないので、固定の時計で書き出すと、同じフレーム番号にはいつも同じ映像フレームが出る ([ADR-0028](../decisions/0028-external-inputs.md) 決定 7)。`pauseTime()` でスケッチの時刻を止めれば動画も止まる
- **動画は音を鳴らさない。** 下の `Movie.volume()` の注を見る
- **動画の名前はファイル名だけを受け付ける** (ファイルを探す場所は `loadImage(_:)` と同じ)。Processing が受け付ける「ネットワーク上の場所」は、いまの mokume に無い (欠けた形)

## Movie

14 件。`Movie` の行のうち `Sources/MokumeCamera/Movie.swift` の表にある API は、その表を指す。表は利用者向けのドキュメントなので説明を転記しない。ここで足すのは、その表に無い API の区分と、欠けた形である。表の場所は [`Movie` の「操作」の表][movie-table] (`Movie` の説明文の「操作」の節)。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Movie` (クラス) | `Movie`・`createVideo(_:)` | 同等 | 動画ファイルを再生するための入り口。見つからない・開けない・動画として読めないときは投げる (`MovieFailure`)。無い形: ネットワーク上の動画 (名前はファイルだけ) | — |
| `Movie.play()`・`loop()`・`pause()`・`jump()` (4 件) | `Movie.play()`・`loop()`・`pause()`・`jump(_:)` | 同等 | [`Movie` の「操作」の表][movie-table]の同名の行。`play()`・`loop()`・`jump(_:)` は次のフレームで効く | — |
| `Movie.speed()` | `Movie.speed(_:)` | 同等 | [`Movie` の「操作」の表][movie-table]の行。無い形: 負の再生速度 (逆再生)。`speed(-1)` は再生速度を変えず、1 度だけ警告する | [#2451] |
| `Movie.time()`・`duration()` (2 件) | `Movie.time`・`Movie.duration` | 同等 | [`Movie` の「操作」の表][movie-table]の行。どちらも秒の `Float` のプロパティ | [#2451] |
| `Movie.available()` | `Movie.isNewFrame` | 同等 | [`Movie` の「操作」の表][movie-table]の `available()` / `read()` の行の前半。プロパティで、そのフレームに新しい映像フレームが `image` へ書き込まれたかを返す。Processing は `read()` するまで `true` のままだが、`isNewFrame` は 1 フレームごとに決まる | — |
| `Movie.noLoop()` | `Movie.play()` (`loop()` で再生している間に呼ぶ) | 同等 | `loop()` で再生している間に `play()` を呼ぶと、今回の再生の終わりで止まり、最後の映像フレームが残る。止まっている動画に `play()` を呼ぶと再生を始める。`noLoop()` という名前の API は足さない (同じ働きの API があるので) | — |
| `Movie.read()` | — (`draw()` の前に `image` が書かれる) | 持たない | [`Movie` の「操作」の表][movie-table]の `available()` / `read()` の行の後半。読み取りの API は要らず、`image` を描けばよい | — |
| `Movie.stop()` | `Movie.pause()` と `Movie.jump(0)` | 持たない | Processing の `stop()` は止めて先頭へ戻す。mokume は止める (`pause()`) と先頭へ移動する (`jump(0)`) の 2 つの API で書く。`Movie.swift` の表に行は無い | — |
| `Movie.frameRate()` | — | 作例待ち | 「読み込む頻度を指定する」意味の選択が分かれる。(1) 表示する映像フレームを間引く (スケッチは 60 fps のまま、動画の映像フレームを毎秒 4 枚しか更新しない。見た目が変わる)、(2) デコードする頻度を下げる (表示される映像フレームの更新の仕方は変えず、負荷だけを下げる)。mokume は毎フレームの映像フレームを再生位置で決めるので、どちらも API の形 (引数か、別の API か) から選ぶ必要がある。作例が来てから選ぶ | — |
| `movieEvent()` | — (`draw()` の中で `isNewFrame` を見る) | 持たない | 新しい映像フレームが届いたときに呼ばれるコールバックで、Processing も「その中では描けない」と書く。mokume は OS の受信用のコールバックを利用者に公開せず、映像フレームは `draw()` の前に 1 回だけ取り出す ([ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 7) | — |

### 参照に載らない API (件数に数えない)

`Movie.volume()` はリファレンスの JSON に項目が無い (Javadoc にだけある API は数えない・README の「バージョン」)。ただし `Movie.swift` の表に行があるので、区分をここに転記する。

- **`Movie.volume()` は持たない。** 同じファイルを `loadSound` で鳴らし、`jump` で映像の位置へ合わせる。`Movie` の音を `Movie` の位置に従わせる案 (#3452 の A) へ進む条件は、`MokumeCamera` と `MokumeAudio` の境界を先に決めることである ([#3452]・PR [#3541]。[#3133] の 2026-10-30 のコメント)

## Capture

7 件。Processing の `Capture` はカメラの入力で、mokume の API は `MokumeCamera` にある。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Capture` (クラス) | `Capture`・`createCapture(_:_:device:mirrored:)` | 同等 | カメラの映像を受け取る入り口。大きさは引数で要求する (既定 640×480)。使うカメラは名前の文字列ではなく、`captureDevices()` が返す `CaptureDevice` で選ぶ (リファレンスの説明に出る `Capture.list()` に当たる)。無い形: フレームレートを渡す形 `Capture(parent, width, height, fps)` ほか (下の `frameRate()`)。カメラが無くても作れ、`state` が理由を返す (許可待ち・拒否された・カメラが無い・取り外された) | — |
| `Capture.available()` | `Capture.isNewFrame` | 同等 | `Movie.available()` と同じ。プロパティで、そのフレームに新しい映像フレームが `image` へ書き込まれたか | — |
| `Capture.stop()` | `Capture.stop()` | 同等 | カメラを閉じ、以後 `image` は変わらない。**止めたものは取り付け直しても止まったまま**で、受け始めるには新しく作る (下の `start()`) | — |
| `Capture.read()` | — (`draw()` の前に `image` が書かれる) | 持たない | `Movie.read()` と同じ。読む API は要らず、`image` を描けばよい | — |
| `Capture.start()` | — (`createCapture(…)` が開く) | 持たない | 作った呼び出しがカメラを開くので、始める API は要らない。呼んだときだけデバイスを開き、`import` しただけではカメラが起動しない。止めたカメラを再び始める API も持たず、新しく作る | — |
| `Capture.frameRate()` | — | 作例待ち | カメラが映像を出す頻度を要求する意味の選択が分かれる。(1) デバイスのフレームレートを選ぶ (`CaptureDevice.formats` の `frameRates` に一覧はあるが、選ぶ API は無い。`createCapture` の引数か、`CaptureFormat` を渡す形か)、(2) 届いた映像を間引く (`Movie.frameRate()` と同じ)。どれを API にするかは作例が来てから選ぶ | — |
| `captureEvent()` | — (`draw()` の中で `isNewFrame` を見る) | 持たない | `movieEvent()` と同じ理由 ([ADR-0042](../decisions/0042-camera-and-audio-standard.md) 決定 7) | — |

[movie-table]: ../../Sources/MokumeCamera/Movie.swift
[#2451]: https://github.com/mokume-metal/mokume/issues/2451
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3452]: https://github.com/mokume-metal/mokume/issues/3452
[#3541]: https://github.com/mokume-metal/mokume/pull/3541
