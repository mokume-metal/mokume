// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension SketchPart {
    /// ファイルを選ばせるダイアログを出し、選んだファイルの絶対パスを返す。**取り消すと `nil`。**
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func mousePressed() {
    ///     Task {
    ///         if let path = await selectInput("CSV を選ぶ") {
    ///             table = try? loadTable(path, header: true)
    ///         }
    ///     }
    /// }
    ///
    /// func draw() {
    ///     background(20)
    ///     if let table {
    ///         for (i, row) in table.rows.enumerated() {
    ///             let high = row.getFloat("value") * 4
    ///             rect(40 + Float(i) * 30, height - high, 24, high)
    ///         }
    ///     } else {
    ///         fill(200)
    ///         text("クリックして CSV を選ぶ", 20, 40)
    ///     }
    /// }
    /// ```
    ///
    /// 選んだファイルが CSV として読めなければ `table` は `nil` のままで、案内の文字が出続けるので、
    /// `Task` の中の `try?` で受けている。
    ///
    /// Processing の `selectInput(prompt, callback)` に当たる。コールバックの代わりに `async` で結果を返す。
    /// 返るパスは絶対パスで、ファイルを読む口に渡せる。**結果は `Task` の続きで届き、そこでは走っている実行が
    /// 外れているので、`Task` の中でそのまま読めるかは口による。**
    ///
    /// - **待つ口がある** (``requestImage(_:)``・``requestTable(_:header:)``・`requestSound(_:)`): `Task` の中ではこちらへ
    ///   渡す。同期の ``loadImage(_:)``・`loadSound(_:)` は `notRunning` (``ImageFailure/notRunning(call:)`` など) を投げる。
    ///   パスを持ち越して次の `draw()` で同期の口を呼ぶと、フレームを止める読み込みの警告が出る
    /// - **面を使わない口**: ``loadTable(_:header:)``・`loadFont(_:)` は `Task` の中でも読める (上の例)
    /// - **待つ口が無い口** (動画の `createVideo(_:)`・音声ファイルを入力として解析する `createAudioIn(file:)`): `Task` の中では
    ///   作れない。パスを持ち越し、次の `draw()` などの、走っている実行の中で作る
    ///
    /// ## 呼び方
    ///
    /// ``requestImage(_:)`` などの `request…` の口と同じで、**`setup()` かコールバックの中で `Task` を起こし、
    /// そこから呼ぶ。** 待っている間もフレームは回り、`draw()` は呼ばれ続ける (上の例は、選ぶまで案内の文字を
    /// 出している)。`draw()` の中で `await` はできない。
    ///
    /// ## ダイアログを出すのはウィンドウを持つ側
    ///
    /// 直に走らせたウィンドウ (`mokume run`・束ねた `.app`) では、そのウィンドウが出す。`mokume watch` の下では、ウィンドウを持つのは
    /// 道具で、スケッチはウィンドウを持たないので、**道具の作品のウィンドウが出す** (プレビューは出さない)。どちらでも、選んだ
    /// 結果は入力の出来事 (外から送る線では `{"type": "fileSelected", "paths": ["/tmp/a.csv"]}`、取り消しは
    /// `"paths": []`) としてフレームの頭に届き、待ちを終える。ウィンドウの無い実行 (`mokume render`) では、外から
    /// 結果を送るまで返らない — 検査や自動操縦は、`.mokume/input` や MCP の `input` で `fileSelected` を送って
    /// 待ちを終えられる。
    ///
    /// 道具のウィンドウが子へ送る結果には、頼みの通し番号 (`"serial"`) が載る。**番号が合わない結果は黙って捨てられる**
    /// ので、頼み直した後に前の頼みの古い答えが届いても、新しい待ちは終わらない。管が一杯などで結果の 1 行が
    /// 落ちても、道具は頼みが残っている間は送り直すので、待ちは永久には続かない。外から送る結果は `serial`
    /// を省いてよく、省くといまの待ちへ届く。
    ///
    /// **限界: 道具のウィンドウがこの口を知らない古い版だと、ダイアログは出ず、待ちは終わらない。** 子は道具の版を知れず、
    /// 頼みを面に載せても読む者がいない。新しい `mokume` を起こし直すか、外から結果を送れば待ちは終わる。
    ///
    /// ## 待てるのは 1 つ
    ///
    /// 1 度に待てるダイアログは 1 つで、``selectOutput(_:)``・``selectFolder(_:)`` と待ちを共有する。待っている間に
    /// どれかをもう 1 度呼ぶと、**前の待ちは `nil` (取り消しと同じ) で終わり**、新しい頼みのダイアログが出る。
    /// 待っていないときに結果が届いても、捨てられる。
    ///
    /// ## 戻る時刻は約束しない
    ///
    /// 結果は入力の出来事なので、待ちが終わるのは**届いたフレームの頭**である。`await` が戻る時刻がどの
    /// フレームの境界か、`noLoop()` で止めている間や `render` で届いた結果をどう扱うかは、
    /// ``requestImage(_:)`` と同じく [#2760] と合わせて決めるので、いまの振る舞いであって約束ではない。呼んだ
    /// `Task` を取り消しても待ちは終わらない (取消の扱いも [#2760])。
    ///
    /// **macOS のウィンドウで出す。** 自前のウィンドウと道具のウィンドウに加えて、``SketchView`` ではホストのウィンドウのシートで出る
    /// (ホストのアプリが前面になる)。**ホストのウィンドウが見えていないあいだは出さず**、見えるまで頼みは残る。
    /// **`SketchView` が消える・ウィンドウから外れる・ホストのアプリが終わるときは、開いているシートは閉じて、取り消しとして
    /// `nil` で終わる。** iOS と、セキュリティスコープ付きの URL は [#2605] で決める。選べるのは在るファイル 1 つで、
    /// 保存先は ``selectOutput(_:)``、フォルダは ``selectFolder(_:)`` で選ばせる。
    ///
    /// - Parameter prompt: ダイアログに添える文言。
    /// - Returns: 選んだファイルの絶対パス。取り消したら `nil`。走っている実行の外から呼んだら、あるいは実行が
    ///   終わった後に呼んだら、ダイアログを頼まず待たずに `nil` (口ごとに 1 度だけ警告する)。待っている最中に実行が
    ///   終わったときも、待ちは `nil` で終わる。
    ///
    /// [#2760]: https://github.com/mokume-metal/mokume/issues/2760
    /// [#2605]: https://github.com/mokume-metal/mokume/issues/2605
    // shot: 撮れない 結果が選んだ人の手元のファイルで、ダイアログはウィンドウの外に出る
    public func selectInput(_ prompt: String) async -> String? {
        // **終わった実行の頼みも、外からの呼び出しと同じに扱う** — 結果を届ける合流点はもう配られず、待てば返らない
        guard let selection = LaunchingSketch.selection, !selection.isEnded else {
            OutsideRun.log.warn(.selectInput)
            return nil
        }
        return await selection.request(prompt, kind: .file)
    }

    /// 保存先を選ばせるダイアログを出し、選んだ置き場の絶対パスを返す。**取り消すと `nil`。**
    ///
    /// <!-- example: 文脈 var notes: [String] = [] -->
    /// ```swift
    /// func mousePressed() {
    ///     notes.append("\(frameCount): \(mouseX), \(mouseY)")
    /// }
    ///
    /// func keyPressed() {
    ///     let lines = notes
    ///     Task {
    ///         if let path = await selectOutput("保存先を選ぶ") {
    ///             try? saveStrings(lines, path)
    ///         }
    ///     }
    /// }
    ///
    /// func draw() {
    ///     background(20)
    ///     fill(200)
    ///     text("クリックで記録、キーで保存先を選んで書く (\(notes.count) 行)", 20, 40)
    /// }
    /// ```
    ///
    /// 例は書けなくても `notes` が残り、もう 1 度キーを押せば選び直せるので、`try?` で受けている。
    ///
    /// Processing の `selectOutput(prompt, callback)` に当たる。返るのは**まだ無いファイルでもよい置き場**で、
    /// ダイアログは書くことを確かめるだけでファイルを作らない。在るファイルを選べば、ダイアログが置き換えてよいかを
    /// 尋ねる。書くのはスケッチで、渡すのは ``saveStrings(_:_:)``・``saveTable(_:_:)`` のような書く API である。
    ///
    /// 呼び方・ダイアログを出す側 (直に走らせたウィンドウ・`mokume watch` の道具のウィンドウ・``SketchView`` の
    /// ホストのウィンドウのシート)・結果の届き方 (入力の出来事 `fileSelected` の `paths`。取り消しは空の配列)・
    /// 戻る時刻は ``selectInput(_:)`` と同じである。`mokume render` のようにウィンドウの無い実行では、外から
    /// `fileSelected` を送るまで返らない。
    ///
    /// **待ちは ``selectInput(_:)``・``selectFolder(_:)`` と 1 つを共有する。** 待っている間にどれかを呼ぶと、
    /// 前の待ちは `nil` で終わる。
    ///
    /// **限界: 道具のウィンドウがこの API より古い版だと、保存先ではなく在るファイルを選ばせるダイアログが出る**
    /// (古い道具は頼みの種類を読まない)。新しい `mokume` を起こし直せば保存先のダイアログになる。
    ///
    /// - Parameter prompt: ダイアログに添える文言。
    /// - Returns: 選んだ置き場の絶対パス。取り消したら `nil`。走っている実行の外から呼んだら、あるいは実行が
    ///   終わった後に呼んだら、ダイアログを頼まず待たずに `nil` (API ごとに 1 度だけ警告する)。
    // shot: 撮れない 結果が選んだ人の手元の置き場で、ダイアログはウィンドウの外に出る
    public func selectOutput(_ prompt: String) async -> String? {
        guard let selection = LaunchingSketch.selection, !selection.isEnded else {
            OutsideRun.log.warn(.selectOutput)
            return nil
        }
        return await selection.request(prompt, kind: .output)
    }

    /// フォルダを選ばせるダイアログを出し、選んだフォルダの絶対パスを返す。**取り消すと `nil`。**
    ///
    /// <!-- example: 文脈 var folder: String? -->
    /// ```swift
    /// func mousePressed() {
    ///     Task {
    ///         if let chosen = await selectFolder("書き出すフォルダを選ぶ") {
    ///             folder = chosen
    ///         }
    ///     }
    /// }
    ///
    /// func keyPressed() {
    ///     if let folder {
    ///         save(folder + "/frame-\(frameCount).png")
    ///     }
    /// }
    ///
    /// func draw() {
    ///     background(20)
    ///     circle(mouseX, mouseY, 40)
    ///     fill(200)
    ///     text(folder ?? "クリックしてフォルダを選ぶ", 20, 40)
    /// }
    /// ```
    ///
    /// ``save(_:)`` は `Task` の中では頼めないので、選んだパスを持ち越して `keyPressed()` で使っている。
    ///
    /// Processing の `selectFolder(prompt, callback)` に当たる。返るのはフォルダ 1 つの絶対パスで、末尾に `/` は
    /// 付かない。ダイアログの中で新しいフォルダを作って選ぶこともできる。
    ///
    /// 呼び方・ダイアログを出す側・結果の届き方・戻る時刻は ``selectInput(_:)`` と同じである。**待ちは
    /// ``selectInput(_:)``・``selectOutput(_:)`` と 1 つを共有する。** 待っている間にどれかを呼ぶと、前の待ちは
    /// `nil` で終わる。
    ///
    /// **限界: 道具のウィンドウがこの API より古い版だと、フォルダではなくファイルを選ばせるダイアログが出る**
    /// (古い道具は頼みの種類を読まない)。新しい `mokume` を起こし直せばフォルダのダイアログになる。
    ///
    /// - Parameter prompt: ダイアログに添える文言。
    /// - Returns: 選んだフォルダの絶対パス。取り消したら `nil`。走っている実行の外から呼んだら、あるいは実行が
    ///   終わった後に呼んだら、ダイアログを頼まず待たずに `nil` (API ごとに 1 度だけ警告する)。
    // shot: 撮れない 結果が選んだ人の手元のフォルダで、ダイアログはウィンドウの外に出る
    public func selectFolder(_ prompt: String) async -> String? {
        guard let selection = LaunchingSketch.selection, !selection.isEnded else {
            OutsideRun.log.warn(.selectFolder)
            return nil
        }
        return await selection.request(prompt, kind: .folder)
    }
}
