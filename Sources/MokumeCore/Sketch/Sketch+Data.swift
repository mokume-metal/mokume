// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 文字列・表・JSON・XML。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 描き場所に触れないので、``Canvas`` に転送先を持たない。走っていなくても (`init` の中でも)
// 読み書きできる。
//
// 読む口はどれも、名前が `http://` か `https://` で始まれば URL から読む (Processing の
// `loadStrings` / `loadTable` / `loadJSONObject` / `loadXML` と同じく、同じ口が URL を受ける)。
// URL かどうかの判定と取得は ``WebFile`` の 1 か所を通る (#2070・#2470)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension SketchPart {

    // MARK: - 文字列

    /// 文字のファイルか URL を読み、1 行ずつの文字列にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var lines: [String] = [] -->
    /// ```swift
    /// func setup() {
    ///     lines = (try? loadStrings("data/poem.txt")) ?? []
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     for (i, line) in lines.enumerated() {
    ///         text(line, 40, 60 + Float(i) * 28)
    ///     }
    /// }
    /// ```
    ///
    /// 読むのは **UTF-8** の文字。行の終わりは LF・CRLF・CR のどれでもよく、返る文字列に
    /// 改行は含まれない。**最後の改行は行を作らない** (`"a\nb\n"` は 2 行)。途中の空の行は
    /// 空の文字列として残る。先頭の BOM は読み飛ばす。
    ///
    /// **名前が `http://` か `https://` で始まれば、その URL から読む。** それ以外はファイルの
    /// 名前で、探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。URL の扱い (届くまで返らない・
    /// 最長 60 秒・2xx 以外は届かなかったものとして投げる) は ``loadJSONObject(_:)`` と同じ。
    ///
    /// **読み込みは投げる。** 読めなかったときに別の道を選ぶ判断が要るので、黙って空へ
    /// 倒さない。見つからないときの説明には**探した場所**が載る。
    ///
    /// - Throws: 見つからないときに ``DataFailure/notFound(path:searched:)``、見つかったが開け
    ///   ない (ディレクトリだった・読む権利が無い) ときに
    ///   ``DataFailure/unopenable(path:location:reason:)`` (解けた場所が載る)、URL から受け取れない
    ///   (繋がらない・時間切れ・2xx 以外の状態) ときに ``DataFailure/unreachable(url:reason:)``、
    ///   UTF-8 の文字として読めないときに ``DataFailure/unreadable(path:)``。
    // shot: 撮れない 読んだ文字列を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadStrings(_ path: String) throws(DataFailure) -> [String] {
        Self.noticeBlockingLoad("loadStrings(_:)", instead: "requestStrings(_:)")
        return TextFile.lines(of: try readText(path))
    }

    /// 文字のファイルか URL を読み、1 行ずつの文字列にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var lines: [String] = [] -->
    /// ```swift
    /// func setup() {
    ///     Task { lines = (try? await requestStrings("data/poem.txt")) ?? [] }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     for (i, line) in lines.enumerated() {
    ///         text(line, 40, 60 + Float(i) * 28)
    ///     }
    /// }
    /// ```
    ///
    /// 読み方と失敗は ``loadStrings(_:)`` と同じ。呼び方と届く前の扱いは ``requestImage(_:)``
    /// と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。** 届くまでの ``Sketch/draw()`` は
    /// 文字列が無いまま呼ばれる。
    // shot: 撮れない 読んだ文字列を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func requestStrings(_ path: String) async throws(DataFailure) -> [String] {
        try await requestParsed(path) { text throws(DataFailure) in TextFile.lines(of: text) }
    }

    /// 文字列を 1 行ずつ、文字のファイルにする。書き終わるまで返らない。
    ///
    /// <!-- example: 文脈 var notes: [String] = [] -->
    /// ```swift
    /// func mousePressed() {
    ///     notes.append("\(frameCount): \(mouseX), \(mouseY)")
    ///     try? saveStrings(notes, "out/notes.txt")
    /// }
    /// ```
    ///
    /// 文字は UTF-8 (BOM なし)、行の終わりは LF で、最後の行にも LF を付ける。書いたファイルを
    /// ``loadStrings(_:)`` で読み直すと、同じ並びに戻る。
    ///
    /// **改行を含む要素は、読み直すと行が分かれる** (`["a\nb"]` は `["a", "b"]` に戻る)。最初の要素の
    /// 頭の U+FEFF (BOM と同じ文字) は、読み直すと ``loadStrings(_:)`` が BOM として落とす。どちらも
    /// 中身を変えずに書き、そのことを 1 度だけ知らせる。
    ///
    /// 引数は書く値が先で、置き場が後 (``saveTable(_:_:)`` と同じ順)。Processing の
    /// `saveStrings(filename, data)` とは逆で、p5.js の `saveStrings(list, filename)` と同じ。置き場・
    /// 途中のディレクトリ・書きかけを残さないことは ``saveTable(_:_:)`` と同じ。
    ///
    /// - Throws: 書けなかったときに ``DataFailure/unwritable(path:reason:)``。
    // shot: 撮れない 結果が絵ではなくファイルになる
    public func saveStrings(_ strings: [String], _ path: String) throws(DataFailure) {
        try TextFile.write(StringLines.format(strings), to: path)
        StringLines.warnIfLossy(strings, path: path)
    }

    // MARK: - 表

    /// CSV のファイルか URL を読み、表にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     table = try? loadTable("data/temperatures.csv", header: true)
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let table else { return }
    ///     for (i, row) in table.rows.enumerated() {
    ///         let high = row.getFloat("high") * 10
    ///         rect(Float(i) * 3, height - high, 2, high)
    ///     }
    /// }
    /// ```
    ///
    /// `header` が `true` なら、最初の行を列の名前 (見出し) として読み、名前で値を引ける
    /// (``TableRow/getFloat(_:)-(String)``)。`false` (既定) なら最初の行も値の行で、列は
    /// 番号で引く (``TableRow/getFloat(_:)-(Int)``)。
    ///
    /// ## 読み方
    ///
    /// - 区切りはカンマだけ。行の終わりは LF・CRLF・CR のどれでもよい。文字は UTF-8 で、
    ///   先頭の BOM は読み飛ばす
    /// - `"…"` で囲んだセルの中のカンマと改行は値の一部で、`""` は `"` 1 つ
    /// - **最後の改行と、中身の無い行は行を作らない**
    /// - セルは文字のまま持ち、数として読むのは取り出すとき
    ///
    /// ## 壊れた CSV は投げる
    ///
    /// **閉じない引用符と、列の数が見出し (見出しが無ければ最初の行) と違う行は、壊れていた行を
    /// 添えて投げる** (``DataFailure/malformed(path:line:reason:)``)。詰めたり捨てたりして
    /// 読み進めると、値が 1 列ずつずれた表が黙って返るためである。
    ///
    /// **名前が `http://` か `https://` で始まれば、その URL から読む** (「ウェブに公開」した
    /// スプレッドシートの CSV など)。それ以外はファイルの名前で、探す場所は ``loadImage(_:)`` と同じ
    /// (``assetURL(_:)``)。URL の扱い (届くまで返らない・最長 60 秒・2xx 以外は届かなかったものとして
    /// 投げる) は ``loadJSONObject(_:)`` と同じで、URL の本文もファイルと同じ決まりで読む。
    ///
    /// - Throws: ``DataFailure``。見つからない (``DataFailure/notFound(path:searched:)``)・
    ///   見つかったが開けない (ディレクトリだった・読む権利が無い。解けた場所が載る。
    ///   ``DataFailure/unopenable(path:location:reason:)``)・URL から受け取れない
    ///   (``DataFailure/unreachable(url:reason:)``)・UTF-8 の文字として読めない
    ///   (``DataFailure/unreadable(path:)``)・CSV として壊れている
    ///   (``DataFailure/malformed(path:line:reason:)``) とき。
    // shot: 撮れない 読んだ表を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadTable(_ path: String, header: Bool = false) throws(DataFailure) -> Table {
        Self.noticeBlockingLoad("loadTable(_:header:)", instead: "requestTable(_:header:)")
        return Table(try TableFile.parse(try readText(path), header: header, path: path))
    }

    /// CSV のファイルか URL を読み、表にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     Task {
    ///         while true {
    ///             table = try? await requestTable("https://sheets.example/pub?output=csv", header: true)
    ///             try? await Task.sleep(for: .seconds(30))
    ///         }
    ///     }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let table else { return }
    ///     for (i, row) in table.rows.enumerated() {
    ///         let high = row.getFloat("value") * 4
    ///         rect(40 + Float(i) * 30, height - high, 24, high)
    ///     }
    /// }
    /// ```
    ///
    /// 「ウェブに公開」したスプレッドシートの CSV を 30 秒ごとに読み直し、値の列を棒の高さにする。
    /// スプレッドシートの値を書き換えると、30 秒以内に棒が変わる。
    ///
    /// 読み方と失敗は ``loadTable(_:header:)`` と同じ。呼び方と届く前の扱いは
    /// ``requestImage(_:)`` と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。**
    /// 大きな表を読んでもフレームが詰まらない。
    // shot: 撮れない 読んだ表を返す口で、例の URL は引けない名前なので応答が届かない
    public func requestTable(_ path: String, header: Bool = false) async throws(DataFailure) -> Table {
        Table(
            try await requestParsed(path) { text throws(DataFailure) in
                try TableFile.parse(text, header: header, path: path)
            })
    }

    /// 表を CSV のファイルにする。書き終わるまで返らない。
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     do {
    ///         var read = try loadTable("data/temperatures.csv", header: true)
    ///         read.addColumn("mean")
    ///         for (i, row) in read.rows.enumerated() {
    ///             read.setFloat(i, "mean", (row.getFloat("high") + row.getFloat("low")) / 2)
    ///         }
    ///         try saveTable(read, "out/temperatures-with-mean.csv")
    ///         table = read
    ///     } catch {
    ///         print(error)
    ///     }
    /// }
    /// ```
    ///
    /// 見出しを持つ表なら、最初の行に見出しを書く。文字は UTF-8 (BOM なし)、行の終わりは LF。
    /// `"…"` で囲むのは、カンマ・引用符・改行を含むセル、頭が U+FEFF (BOM と同じ文字) のセル、
    /// 1 列の表の空のセルだけ — ``loadTable(_:header:)`` はファイルの先頭の BOM と中身の無い行を
    /// 読み飛ばすので、囲まないと最初のセルの頭の U+FEFF や、空の行が消える。書いたファイルを
    /// ``loadTable(_:header:)`` で (見出しを持つ表なら `header: true` で) 読み直すと、同じ表に戻る。
    ///
    /// 置き場は**作業ディレクトリが基準** (``save(_:)`` と同じ)。途中のディレクトリは無ければ
    /// 作る。**書きかけを残さない** — 隣の一時ファイルへ書いてから置き換えるので、途中で
    /// 止まっても前の中身か新しい中身のどちらかが残る。
    ///
    /// **書き出しは投げる。** 書けなかったときに別の道を選ぶ判断が要るので、黙って
    /// 捨てない。
    ///
    /// - Throws: 書けなかったときに ``DataFailure/unwritable(path:reason:)``。
    // shot: 撮れない 結果が絵ではなくファイルになる
    public func saveTable(_ table: Table, _ path: String) throws(DataFailure) {
        try TextFile.write(TableFile.format(titles: table.titles, rows: table.cells), to: path)
    }

    // MARK: - JSON

    /// JSON のファイルか URL を読み、オブジェクトにする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var weather: JSONObject? -->
    /// ```swift
    /// func setup() {
    ///     weather = try? loadJSONObject("data/weather.json")
    /// }
    ///
    /// func draw() {
    ///     guard let weather else {
    ///         background(90)
    ///         return
    ///     }
    ///     let warmth = constrain(norm(weather.getJSONObject("main").getFloat("temp"), -10, 35), 0, 1)
    ///     background(lerp(70, 240, warmth), lerp(130, 140, warmth), lerp(220, 60, warmth))
    /// }
    /// ```
    ///
    /// 値はキーで取り出す (``JSONObject/getJSONObject(_:)`` で入れ子へ降り、
    /// ``JSONObject/getFloat(_:)`` で数を、``JSONObject/getString(_:)`` で文字を取り、
    /// ``JSONObject/getJSONArray(_:)`` で配列を回す)。読む前に応答の形を型として宣言しなくてよい。
    ///
    /// **名前が `http://` か `https://` で始まれば、その URL から読む。** それ以外はファイルの
    /// 名前で、探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。
    ///
    /// **URL を渡すと、届くまで返らない** — 届き終わるか、届かないと分かるまで待つ。待つのは
    /// **呼んでから最長 60 秒**で、少しずつ届き続けていても、60 秒で届き終わらなければ諦めて
    /// 投げる。`setup()` の中で 1 度読むためのもので、待つ間は窓も描かれない。フレームを止めずに
    /// 読むのは ``requestJSONObject(_:)`` である。
    ///
    /// ## 読み方
    ///
    /// - 文字は UTF-8 (ファイルも URL の本文も)。先頭の BOM は読み飛ばす
    /// - **最上位はオブジェクト (`{…}`) でなければならない** (配列の JSON は ``loadJSONArray(_:)``)
    /// - 入れ子は、最上位の下に 512 段まで。`Double` に収まらない数 (`1e400`・`-1e400`) は、
    ///   符号によらず読めない
    ///
    /// ## 読めないときは投げる
    ///
    /// 読めなかったときに別の道を選ぶ判断が要るので、黙って空へ倒さない。
    ///
    /// - ファイルが見つからない: ``DataFailure/notFound(path:searched:)`` (探した場所が載る)
    /// - ファイルが見つかったが開けない (ディレクトリだった・読む権利が無い):
    ///   ``DataFailure/unopenable(path:location:reason:)`` (解けた場所が載る)
    /// - URL から受け取れない (繋がらない・時間切れ・サーバが 2xx 以外の状態で答えた):
    ///   ``DataFailure/unreachable(url:reason:)``
    /// - UTF-8 の文字として読めない: ``DataFailure/unreadable(path:)``
    /// - JSON として壊れている・`Double` に収まらない数がある・最上位がオブジェクトでない:
    ///   ``DataFailure/malformed(path:line:reason:)`` (壊れていた行が載る)。最上位が配列だったときは、
    ///   理由が ``loadJSONArray(_:)`` を案内する
    ///
    /// - Throws: 上のどれか (``DataFailure``)。
    // shot: 撮れない 読んだ値を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadJSONObject(_ path: String) throws(DataFailure) -> JSONObject {
        Self.noticeBlockingLoad("loadJSONObject(_:)", instead: "requestJSONObject(_:)")
        return JSONObject(
            try JSONFile.parseObject(try readText(path), path: path, instead: "loadJSONArray(_:)"))
    }

    /// JSON のファイルか URL を読み、オブジェクトにする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var temp: Float?; var reason = "" -->
    /// ```swift
    /// func setup() {
    ///     Task {
    ///         do {
    ///             temp = try await requestJSONObject("https://weather.example/now")
    ///                 .getJSONObject("main").getFloat("temp")
    ///         } catch {
    ///             reason = "\(error)"
    ///         }
    ///     }
    /// }
    ///
    /// func draw() {
    ///     if let temp {
    ///         let warmth = constrain(norm(temp, -10, 35), 0, 1)
    ///         background(lerp(70, 240, warmth), lerp(130, 140, warmth), lerp(220, 60, warmth))
    ///     } else {
    ///         background(90)
    ///         text(reason, 20, height - 20)
    ///     }
    /// }
    /// ```
    ///
    /// 天気の API から今の気温を取り、背景を寒色から暖色の間で塗る。届くまでと届かないときは
    /// 灰色で、届かないときは画面の隅に理由 (``DataFailure`` の 1 文) を出す。
    ///
    /// 読み方と失敗は ``loadJSONObject(_:)`` と同じ。呼び方と届く前の扱いは ``requestImage(_:)``
    /// と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。** 届くまでの ``Sketch/draw()`` は
    /// 値が無いまま呼ばれる。
    // shot: 撮れない 読んだ値を返す口で、例の URL は引けない名前なので応答が届かない
    public func requestJSONObject(_ path: String) async throws(DataFailure) -> JSONObject {
        JSONObject(
            try await requestParsed(path) { text throws(DataFailure) in
                try JSONFile.parseObject(text, path: path, instead: "requestJSONArray(_:)")
            })
    }

    /// JSON のファイルか URL を読み、最上位が配列の JSON を配列にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var scores: JSONArray? -->
    /// ```swift
    /// func setup() {
    ///     // ファイルの中身は [{"name": "Ann", "score": 12}, {"name": "Bo", "score": 7}] の形
    ///     scores = try? loadJSONArray("data/scores.json")
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let scores else { return }
    ///     for (i, entry) in scores.enumerated() {
    ///         text("\(entry.getString("name")): \(entry.getInt("score"))", 20, 30 + Float(i) * 24)
    ///     }
    /// }
    /// ```
    ///
    /// 配列は `for-in` で回せ、要素は ``JSONObject`` として渡る (``JSONArray``)。最上位が配列でなく
    /// オブジェクトの JSON (`{…}`) は ``loadJSONObject(_:)`` で読む。
    ///
    /// 名前の扱い (`http://` か `https://` で始まれば URL から読み、届くまで返らない。最長 60 秒)・
    /// 探す場所・文字の読み方・読めないときに投げる失敗は ``loadJSONObject(_:)`` と同じである。
    /// 違うのは最上位だけで、**配列でない JSON (オブジェクト・数・文字) は**
    /// ``DataFailure/malformed(path:line:reason:)`` で、最上位の値が始まる行を添えて投げる。理由は、
    /// オブジェクトだったときに ``loadJSONObject(_:)`` を案内する。
    ///
    /// **`draw()` の中で呼ぶと、フレームが止まる**ので、``loadJSONObject(_:)`` と同じく口の名前で
    /// 1 度だけ知らせ、``requestJSONArray(_:)`` を案内する。
    ///
    /// - Throws: ``DataFailure``。投げる場合は ``loadJSONObject(_:)`` と同じ。
    // shot: 撮れない 読んだ値を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadJSONArray(_ path: String) throws(DataFailure) -> JSONArray {
        Self.noticeBlockingLoad("loadJSONArray(_:)", instead: "requestJSONArray(_:)")
        return JSONArray(
            try JSONFile.parseArray(try readText(path), path: path, instead: "loadJSONObject(_:)"))
    }

    /// JSON のファイルか URL を読み、最上位が配列の JSON を配列にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var scores: JSONArray? -->
    /// ```swift
    /// func setup() {
    ///     Task { scores = try? await requestJSONArray("https://scores.example/top.json") }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let scores else { return }
    ///     for (i, entry) in scores.enumerated() {
    ///         text("\(entry.getString("name")): \(entry.getInt("score"))", 20, 30 + Float(i) * 24)
    ///     }
    /// }
    /// ```
    ///
    /// 読み方と失敗は ``loadJSONArray(_:)`` と同じ。呼び方と届く前の扱いは ``requestImage(_:)``
    /// と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。** 届くまでの ``Sketch/draw()`` は
    /// 値が無いまま呼ばれる。
    // shot: 撮れない 読んだ値を返す口で、例の URL は引けない名前なので応答が届かない
    public func requestJSONArray(_ path: String) async throws(DataFailure) -> JSONArray {
        JSONArray(
            try await requestParsed(path) { text throws(DataFailure) in
                try JSONFile.parseArray(text, path: path, instead: "requestJSONObject(_:)")
            })
    }

    /// JSON の文字を読み、オブジェクトにする。ファイルも URL も読まない。
    ///
    /// <!-- example: 文脈 var level = 0 as Float -->
    /// ```swift
    /// func mousePressed() {
    ///     // 通信で届いた文字 (たとえばブラウザが送ってきた JSON)
    ///     let message = "{\"level\": 0.8, \"name\": \"slider\"}"
    ///     if let object = try? parseJSONObject(message) {
    ///         level = object.getFloat("level")
    ///     }
    /// }
    /// ```
    ///
    /// TCP・UDP・WebSocket で届くのは文字なので、その文字を ``JSONObject`` にする口である。読み方と
    /// 壊れたときの失敗は ``loadJSONObject(_:)`` と同じで、**最上位はオブジェクト (`{…}`) でなければ
    /// ならない** (配列は ``parseJSONArray(_:)``)。壊れた文字は
    /// ``DataFailure/malformed(path:line:reason:)`` で、壊れていた行を添えて投げる。**`path` には
    /// 口の名前** (`"parseJSONObject(_:)"`) が入る — 文字には名前が無い。
    ///
    /// ファイルを読まず待たないので、`draw()` の中で呼んでも知らせない。
    ///
    /// - Throws: ``DataFailure/malformed(path:line:reason:)``。
    // shot: 撮れない 文字を読んだ値を返す口で、描き場所には触れない
    public func parseJSONObject(_ text: String) throws(DataFailure) -> JSONObject {
        JSONObject(
            try JSONFile.parseObject(
                text, path: "parseJSONObject(_:)", instead: "parseJSONArray(_:)"))
    }

    /// JSON の文字を読み、最上位が配列の JSON を配列にする。ファイルも URL も読まない。
    ///
    /// <!-- example: 文脈 var levels: [Float] = [] -->
    /// ```swift
    /// func mousePressed() {
    ///     let message = "[0.2, 0.5, 0.9]"
    ///     if let array = try? parseJSONArray(message) {
    ///         levels = (0..<array.count).map { array.getFloat($0) }
    ///     }
    /// }
    /// ```
    ///
    /// 読み方と失敗は ``parseJSONObject(_:)`` と同じで、**最上位は配列 (`[…]`) でなければならない**
    /// (オブジェクトは ``parseJSONObject(_:)``)。壊れた文字・配列でない文字は
    /// ``DataFailure/malformed(path:line:reason:)`` で、`path` には口の名前 (`"parseJSONArray(_:)"`)
    /// が入る。
    ///
    /// - Throws: ``DataFailure/malformed(path:line:reason:)``。
    // shot: 撮れない 文字を読んだ値を返す口で、描き場所には触れない
    public func parseJSONArray(_ text: String) throws(DataFailure) -> JSONArray {
        JSONArray(
            try JSONFile.parseArray(
                text, path: "parseJSONArray(_:)", instead: "parseJSONObject(_:)"))
    }

    // MARK: - XML

    /// XML のファイルか URL を読み、根の要素にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var sky: XML? -->
    /// ```swift
    /// func setup() {
    ///     sky = try? loadXML("data/constellation.xml")
    /// }
    ///
    /// func draw() {
    ///     background(12, 16, 32)
    ///     noStroke()
    ///     for star in sky?.getChildren("star") ?? [] {
    ///         circle(star.getFloat("x"), star.getFloat("y"), star.getFloat("size"))
    ///     }
    /// }
    /// ```
    ///
    /// 子の要素は名前で取り出し (``XML/getChildren(_:)``・最初の 1 つは ``XML/getChild(_:)``)、属性は
    /// 数として (``XML/getFloat(_:)``)・文字として (``XML/getString(_:)``) 読む。要素の中の文字は
    /// ``XML/getContent()`` で読む。
    ///
    /// URL の扱い (`http://` か `https://` で始まる名前は URL から読み、届くまで返らない) と、
    /// 探す場所は ``loadJSONObject(_:)`` と同じ。
    ///
    /// ## 読み方
    ///
    /// - 文字は UTF-8 (ファイルも URL の本文も)。先頭の BOM は読み飛ばす。**XML 宣言の
    ///   `encoding` は読まない** — `<?xml version="1.0" encoding="Shift_JIS"?>` と書いてあっても、
    ///   UTF-8 として読めた文書は UTF-8 として読む。値が名前の形 (英字で始まり、英数字と `.` `_` `-`)
    ///   でない宣言 (`encoding=""` など) は、XML として壊れているので `malformed` で投げる
    /// - 行の終わりは LF・CRLF・CR のどれでもよい。壊れた行は、どれで改行した文書でも同じ行を名乗る
    /// - **外の実体 (`<!ENTITY … SYSTEM …>`) は読まない。** XML の中に書かれた名前から、手元の
    ///   ファイルや外の URL を読みに行かない
    /// - 持つのは要素の名前・属性・子の要素・要素の直下の文字。実体参照 (`&amp;`) は解いた値になる
    /// - 入れ子は、根の下に 512 段まで
    ///
    /// ## 読めないときは投げる
    ///
    /// 投げる場合は ``loadJSONObject(_:)`` と同じで、壊れた XML (閉じない要素・閉じる名前の
    /// 食い違い・不正な文字・要素の無い文字・深すぎる入れ子) は ``DataFailure/malformed(path:line:reason:)``
    /// で、壊れていた行を添えて投げる。
    ///
    /// - Throws: ``DataFailure``。
    // shot: 撮れない 読んだ値を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadXML(_ path: String) throws(DataFailure) -> XML {
        Self.noticeBlockingLoad("loadXML(_:)", instead: "requestXML(_:)")
        return XML(try XMLFile.parse(try readText(path), path: path))
    }

    /// XML のファイルか URL を読み、根の要素にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var sky: XML? -->
    /// ```swift
    /// func setup() {
    ///     Task { sky = try? await requestXML("data/constellation.xml") }
    /// }
    ///
    /// func draw() {
    ///     background(12, 16, 32)
    ///     noStroke()
    ///     for star in sky?.getChildren("star") ?? [] {
    ///         circle(star.getFloat("x"), star.getFloat("y"), star.getFloat("size"))
    ///     }
    /// }
    /// ```
    ///
    /// 読み方と失敗は ``loadXML(_:)`` と同じ。呼び方と届く前の扱いは ``requestImage(_:)`` と
    /// 同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。**
    // shot: 撮れない 読んだ値を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func requestXML(_ path: String) async throws(DataFailure) -> XML {
        XML(
            try await requestParsed(path) { text throws(DataFailure) in
                try XMLFile.parse(text, path: path)
            })
    }

    // MARK: - 共通の道

    /// 名前の中身を文字として読む。読み終わるまで返らない。
    ///
    /// URL なら受け取りを待ち、ファイルなら探して読む。どちらも同じ ``TextFile/text(of:path:)``
    /// で解くので、同じ中身は置き場によらず同じ文字になる。
    private func readText(_ path: String) throws(DataFailure) -> String {
        if let url = try WebFile.url(path) {
            return try TextFile.text(of: try WebFile.fetchWaiting(url, path: path), path: path)
        }
        return try TextFile.read(try dataURL(path), path: path)
    }

    /// 名前の中身を読んで解く。**読んでいる間、他の仕事を止めない。**
    ///
    /// URL なら受け取りを待ち (待つ間は他の仕事が進む)、解くのは別の仕事に回す。ファイルなら
    /// 読むのも解くのも別の仕事に回す。
    private func requestParsed<Value: Sendable>(
        _ path: String, _ parse: @escaping @Sendable (String) throws(DataFailure) -> Value
    ) async throws(DataFailure) -> Value {
        if let url = try WebFile.url(path) {
            let body = try await WebFile.fetch(url, path: path)
            return try await Self.readAway { () throws(DataFailure) in
                try parse(try TextFile.text(of: body, path: path))
            }
        }
        let url = try dataURL(path)
        return try await Self.readAway { () throws(DataFailure) in
            try parse(try TextFile.read(url, path: path))
        }
    }

    /// 名前を、在るファイルの場所へ解く。探し方は ``assetURL(_:)`` そのもの。SVG を読む口
    /// (``loadShape(_:)``) も通る。
    func dataURL(_ path: String) throws(DataFailure) -> URL {
        do {
            return try assetURL(path)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            case .unreachable(let path, let location, let reason):
                throw .unopenable(
                    path: path, location: location, reason: AssetOpening.unreachableReason(reason))
            }
        }
    }

    /// 読んで解く仕事を、別の仕事として回して待つ。
    ///
    /// **回す先は、main thread と同じ大きさ (8 MB) のスタックを持つ専用の thread である。**
    /// `Task.detached` が走る共有の thread はスタックが小さく、`JSONSerialization` は 500 段
    /// ほどの入れ子でそれを使い切ってプロセスごと落ちる — 自分の上限 (最上位の下に 512 段) より手前で
    /// (#2070 で確かめた)。同期版は main thread の上で読むので落ちない。**同じファイルが同期版で
    /// だけ読める、を作らない**ために、待たない版も同じ大きさのスタックで読む。SVG を読む待たない口
    /// (``requestShape(_:)``) も同じ理由でここを通す。
    static func readAway<Value: Sendable>(
        _ work: @escaping @Sendable () throws(DataFailure) -> Value
    ) async throws(DataFailure) -> Value {
        let outcome = await withCheckedContinuation {
            (done: CheckedContinuation<Result<Value, DataFailure>, Never>) in
            let reader = Thread {
                done.resume(returning: Result { () throws(DataFailure) in try work() })
            }
            reader.stackSize = 8 << 20
            reader.qualityOfService = .utility
            reader.start()
        }
        return try outcome.get()
    }
}
