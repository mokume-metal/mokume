// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 文字列・表・JSON・XML。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 描き場所に触れないので、``Canvas`` に転送先を持たない。走っていなくても (`init` の中でも)
// 読み書きできる。
//
// JSON と XML の口は、名前が `http://` か `https://` で始まれば URL から読む (Processing の
// `loadJSONObject` / `loadXML` と同じく、同じ口が URL を受ける)。文字列と表の口は、いまは
// ファイルだけを読む — URL から読む作例がまだ無い (#2070)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    // MARK: - 文字列

    /// 文字のファイルを読み、1 行ずつの文字列にする。読み終わるまで返らない。
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
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。
    ///
    /// **読み込みは投げる。** 読めなかったときに別の道を選ぶ判断が要るので、黙って空へ
    /// 倒さない。見つからないときの説明には**探した場所**が載る。
    ///
    /// - Throws: 見つからないときに ``DataFailure/notFound(path:searched:)``、UTF-8 の文字と
    ///   して読めないときに ``DataFailure/unreadable(path:)``。
    // shot: 撮れない 読んだ文字列を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadStrings(_ path: String) throws(DataFailure) -> [String] {
        let url = try dataURL(path)
        return TextFile.lines(of: try TextFile.read(url, path: path))
    }

    /// 文字のファイルを読み、1 行ずつの文字列にする。**読んでいる間、他の仕事を止めない。**
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
    /// と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。** 届くまでの ``draw()`` は
    /// 文字列が無いまま呼ばれる。
    // shot: 撮れない 読んだ文字列を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func requestStrings(_ path: String) async throws(DataFailure) -> [String] {
        let url = try dataURL(path)
        return try await Self.readAway { () throws(DataFailure) in
            TextFile.lines(of: try TextFile.read(url, path: path))
        }
    }

    // MARK: - 表

    /// CSV のファイルを読み、表にする。読み終わるまで返らない。
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
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。
    ///
    /// - Throws: 見つからない・UTF-8 の文字として読めない・CSV として壊れているとき。
    // shot: 撮れない 読んだ表を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadTable(_ path: String, header: Bool = false) throws(DataFailure) -> Table {
        let url = try dataURL(path)
        return Table(try TableFile.parse(try TextFile.read(url, path: path), header: header, path: path))
    }

    /// CSV のファイルを読み、表にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     Task { table = try? await requestTable("data/temperatures.csv", header: true) }
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
    /// 読み方と失敗は ``loadTable(_:header:)`` と同じ。呼び方と届く前の扱いは
    /// ``requestImage(_:)`` と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。**
    /// 大きな表を読んでもフレームが詰まらない。
    // shot: 撮れない 読んだ表を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func requestTable(_ path: String, header: Bool = false) async throws(DataFailure) -> Table {
        let url = try dataURL(path)
        let parsed = try await Self.readAway { () throws(DataFailure) in
            try TableFile.parse(try TextFile.read(url, path: path), header: header, path: path)
        }
        return Table(parsed)
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
    /// カンマ・引用符・改行を含むセルだけを `"…"` で囲む。書いたファイルを ``loadTable(_:header:)``
    /// で読み直すと、同じ表に戻る。
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
    /// ``JSONObject/getFloat(_:)`` で数を取る)。読む前に応答の形を型として宣言しなくてよい。
    ///
    /// **名前が `http://` か `https://` で始まれば、その URL から読む。** それ以外はファイルの
    /// 名前で、探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。
    ///
    /// **URL を渡すと、届くまで返らない** — 届かないと分かるまで (応答が無ければ最長 60 秒)
    /// 待つ。`setup()` の中で 1 度読むためのもので、待つ間は窓も描かれない。フレームを止めずに
    /// 読むのは ``requestJSONObject(_:)`` である。
    ///
    /// ## 読み方
    ///
    /// - 文字は UTF-8 (ファイルも URL の本文も)。先頭の BOM は読み飛ばす
    /// - **最上位はオブジェクト (`{…}`) でなければならない**
    /// - 入れ子は、最上位の下に 512 段まで。`Double` に収まらない数 (`1e400`) は読めない
    ///
    /// ## 読めないときは投げる
    ///
    /// 読めなかったときに別の道を選ぶ判断が要るので、黙って空へ倒さない。
    ///
    /// - ファイルが見つからない: ``DataFailure/notFound(path:searched:)`` (探した場所が載る)
    /// - URL から受け取れない (繋がらない・時間切れ・サーバが 2xx 以外の状態で答えた):
    ///   ``DataFailure/unreachable(url:reason:)``
    /// - UTF-8 の文字として読めない: ``DataFailure/unreadable(path:)``
    /// - JSON として壊れている・最上位がオブジェクトでない:
    ///   ``DataFailure/malformed(path:line:reason:)`` (壊れていた行が載る)
    ///
    /// - Throws: 上のどれか (``DataFailure``)。
    // shot: 撮れない 読んだ値を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadJSONObject(_ path: String) throws(DataFailure) -> JSONObject {
        JSONObject(try JSONFile.parseObject(try readText(path), path: path))
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
    /// と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。** 届くまでの ``draw()`` は
    /// 値が無いまま呼ばれる。
    // shot: 撮れない 読んだ値を返す口で、例の URL は引けない名前なので応答が届かない
    public func requestJSONObject(_ path: String) async throws(DataFailure) -> JSONObject {
        JSONObject(
            try await requestParsed(path) { text throws(DataFailure) in
                try JSONFile.parseObject(text, path: path)
            })
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
    /// 子の要素は名前で取り出し (``XML/getChildren(_:)``)、属性は数として読む
    /// (``XML/getFloat(_:)``)。
    ///
    /// URL の扱い (`http://` か `https://` で始まる名前は URL から読み、届くまで返らない) と、
    /// 探す場所は ``loadJSONObject(_:)`` と同じ。
    ///
    /// ## 読み方
    ///
    /// - 文字は UTF-8 (ファイルも URL の本文も)。先頭の BOM は読み飛ばす
    /// - **外の実体 (`<!ENTITY … SYSTEM …>`) は読まない。** XML の中に書かれた名前から、手元の
    ///   ファイルや外の URL を読みに行かない
    /// - 持つのは要素の名前・属性・子の要素。実体参照 (`&amp;`) は解いた値になる
    /// - 入れ子は、根の下に 512 段まで
    ///
    /// ## 読めないときは投げる
    ///
    /// 投げる場合は ``loadJSONObject(_:)`` と同じ 4 つで、壊れた XML (閉じない要素・閉じる名前の
    /// 食い違い・不正な文字・要素の無い文字・深すぎる入れ子) は ``DataFailure/malformed(path:line:reason:)``
    /// で、壊れていた行を添えて投げる。
    ///
    /// - Throws: ``DataFailure``。
    // shot: 撮れない 読んだ値を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadXML(_ path: String) throws(DataFailure) -> XML {
        XML(try XMLFile.parse(try readText(path), path: path))
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

    /// 名前を、在るファイルの場所へ解く。探し方は ``assetURL(_:)`` そのもの。
    private func dataURL(_ path: String) throws(DataFailure) -> URL {
        do {
            return try assetURL(path)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            }
        }
    }

    /// 読んで解く仕事を、別の仕事として回して待つ。
    ///
    /// **回す先は、main thread と同じ大きさ (8 MB) のスタックを持つ専用の thread である。**
    /// `Task.detached` が走る共有の thread はスタックが小さく、`JSONSerialization` は 500 段
    /// ほどの入れ子でそれを使い切ってプロセスごと落ちる — 自分の上限 (最上位の下に 512 段) より手前で
    /// (#2070 で確かめた)。同期版は main thread の上で読むので落ちない。**同じファイルが同期版で
    /// だけ読める、を作らない**ために、待たない版も同じ大きさのスタックで読む。
    private static func readAway<Value: Sendable>(
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
