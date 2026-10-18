<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

画像・モデル・断片・音・動画を読む口は、名前の指す先が**ディレクトリだったときと、読む権利の無いファイルだったとき**に、それぞれの失敗の型に新しく足した `unopenable(path:location:reason:)` で投げるようになりました ([#2358](https://github.com/mokume-metal/mokume/issues/2358))。足したのは `ImageFailure`・`ModelFailure`・`ShaderFailure`・`AudioFailure`・`MovieFailure` の 5 つで、形は文字のファイルの `DataFailure.unopenable` と同じです。`location` には名前が解けた場所、`reason` には OS が名乗った事情 (`Is a directory`・`Permission denied`) が入り、文面は `"photo.png" was found at "/Users/me/sketch/photo.png" but cannot be opened: Is a directory` の形です (名前が解けた場所と同じなら `at …` は省きます)。

これまでは、中身の形式や破損の失敗に畳んでいました。口ごとに次のとおりです。

| 口 | これまで | これから |
| --- | --- | --- |
| `loadImage`・`requestImage` | `ImageFailure.undecodable` (「形式を確かめよ」) | `ImageFailure.unopenable` |
| `loadModel`・`requestModel` (OBJ・STL) | `ModelFailure.unreadable` (「壊れていないか確かめよ」) | `ModelFailure.unopenable` |
| `loadShader`・`loadEffect`・`loadComputation` | `ShaderFailure.notFound` (見つかっているのに「見つからない・資源の宣言を確かめよ」) | `ShaderFailure.unopenable` |
| `loadSound`・`createAudioIn(file:)` | `AudioFailure.unreadable` (「壊れている・形式」) | `AudioFailure.unopenable` |
| `createVideo` | `MovieFailure.unreadable` (「壊れている・形式」) | `MovieFailure.unopenable` |

中身の壊れたファイル (正しい拡張子で中身が違うもの) は、今までどおり `undecodable` / `unreadable` で投げます。ただし断片 (`loadShader`・`loadEffect`・`loadComputation`) は、開けたが UTF-8 の文字として読めない中身 (Shift_JIS で保存した `.metal` など) も、これまでは `ShaderFailure.notFound` (「見つからない・資源の宣言を確かめよ」) で投げていました。新しく足した `ShaderFailure.unreadable(path:)` で投げ、`DataFailure.unreadable` と同じく「UTF-8 の文字として読めない。UTF-8 で保存し直せ」と名乗ります。保存を拾って断片を読み直したときに読めなくなった場合も、`failure` が場所だけでなく、開けない事情か UTF-8 でないことを名乗ります。`assetURL(_:)` の振る舞いは変わらず、在ればディレクトリも返します。そのため、作業ディレクトリに同梱の資材と同じ名前のフォルダがあると、本物より先にそれが解けて `unopenable` になります。`location` を見れば、どのフォルダが隠しているかが分かります。

移行: 5 つの型のどれかを `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .unopenable(let path, let location, let reason):` の枝 (`ShaderFailure` には `case .unreadable(let path):` も) を足してください。直す先を示すなら、渡した名前 (`path`) ではなく解けた場所 (`location`) を使います。ディレクトリや読む権利の無いファイルを `.undecodable`・`.unreadable`・`ShaderFailure.notFound` の枝で受けていたなら、その扱いを新しい枝へ移します。UTF-8 でない断片を `ShaderFailure.notFound` の枝で受けていたなら、`ShaderFailure.unreadable` の枝へ移します。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、コードの変更は要りません。
