<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

書体のファイルを読んで使えるようになり、文字の太さを 100〜900 で動かせるようになりました ([#2445](https://github.com/mokume-metal/mokume/issues/2445))。`loadFont(_:)` が `.ttf`・`.otf`・`.ttc`・`.otc` を読んで `Font` を返し、`textFont(_:)` に渡すとその書体で描きます。`textWeight(_:)` は太さを数で頼む口で、整数や `Double` の変数をそのまま渡せます。

```swift
func setup() { display = try? loadFont("assets/fonts/Display.otf") }   // var display: Font?

func draw() {
    if let display { textFont(display) }
    textWeight(500 + 400 * sin(time * 2))
    text("mokume", 40, 120)
}
```

**作品に書体を同梱できます。** これまで書体を指す口は、この Mac に入っている書体の名前を受ける `textFont("名前")` だけで、配った先の Mac に同じ書体があるとは限りませんでした。`loadFont` が探す場所と順は `loadImage` と同じです (`assetURL`)。読んだ書体は環境へ登録しないので、同じ名前の書体が入っていても `textFont("名前")` の結果は変わらず、他のアプリにも見えません。同じファイルを更新されないまま読み直すと等しい値になり、焼き場の字形も使い回します。`textWidth`・`textBounds`・`textOutline` も読んだ書体で測ります。

失敗は型のついた `FontFailure` を投げます。無いパスは `notFound` (探した場所つき)、ディレクトリや読む権利の無いファイルは `unopenable` (解けた場所と OS の事情つき)、書体でないファイルは `unreadable` です。`loadFont` は走っている面を使わないので、走っていない所でも読めます。`draw()` の中で呼ぶと、ほかの同期の読み込みと同じく、口の名前を添えて 1 度だけ知らせます (`setup()` で 1 度読んでください)。

**太さは書体が持つ面で決まります。** 既定の書体と、読んだ可変書体は `wght` 軸をそのまま動かすので、`textWeight(300)` と `textWeight(800)` で字の幅も形も変わります (既定の書体の 40 画素の `M` の送り幅は、約 32.9 と約 35.2 です)。可変でない書体は、持つ面のうち最も近い太さの面で描きます (Helvetica は軽い面・標準・太字の 3 通り)。頼んだ太さから 100 を超えて離れた面しか無いときは、使った面を名乗って 1 度だけ警告します。100 未満・900 超は端へ丸めて、数でない値は知らせて前の太さのまま残します。太さは整数に丸めて焼き場の鍵に入るので、`500.2` と `500.4` は同じ字形を使い、`500` と `501` は別に焼きます。**毎フレーム太さを動かすと、大きさを動かすのと同じく焼き直しが続きます** (焼き場の頁が埋まれば頁を替えるので、字は欠けません)。

`textStyle()` と `textWeight()` は、後から呼んだほうが勝ちます。`textStyle(.bold)` の後の `textWeight(300)` は 300 で、`textWeight(300)` の後の `textStyle(.bold)` は太字で描きます。`textStyle(.italic)` の後の `textWeight(300)` は、傾きを残して 300 です。

公開の型の名前は `Font` です。SwiftUI を import するファイルでは `mokume.Font` と書けば解けます (`Image`・`Shape` と同じ扱い)。書体の名前の一覧の口と、待たずに読む `requestFont` はまだありません。
