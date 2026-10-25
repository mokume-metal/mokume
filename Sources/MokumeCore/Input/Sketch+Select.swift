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
    /// Processing の `selectInput(prompt, callback)` に当たる。コールバックの代わりに `async` で結果を返す。
    /// 返るパスは絶対パスで、``loadImage(_:)``・``loadTable(_:header:)`` などにそのまま渡せる。
    ///
    /// ## 呼び方
    ///
    /// ``requestImage(_:)`` などの `request…` の口と同じで、**`setup()` かコールバックの中で `Task` を起こし、
    /// そこから呼ぶ。** 待っている間もフレームは回り、`draw()` は呼ばれ続ける (上の例は、選ぶまで案内の文字を
    /// 出している)。`draw()` の中で `await` はできない。
    ///
    /// ## ダイアログを出すのは窓を持つ側
    ///
    /// 直に走らせた窓 (`mokume run`・束ねた `.app`) では、その窓が出す。`mokume watch` の下では、窓を持つのは
    /// 道具で、スケッチは窓を持たないので、**道具の作品の窓が出す** (プレビューは出さない)。どちらでも、選んだ
    /// 結果は入力の出来事 (外から送る線では `{"type": "fileSelected", "paths": ["/tmp/a.csv"]}`、取り消しは
    /// `"paths": []`) としてフレームの頭に届き、待ちを終える。窓の無い実行 (`mokume render`) では、外から
    /// 結果を送るまで返らない — 検査や自動操縦は、`.mokume/input` や MCP の `input` で `fileSelected` を送って
    /// 待ちを終えられる。
    ///
    /// ## 待てるのは 1 つ
    ///
    /// 1 度に待てる `selectInput` は 1 つ。待っている間にもう 1 度呼ぶと、**前の待ちは `nil` (取り消しと同じ)
    /// で終わり**、新しい頼みのダイアログが出る。待っていないときに結果が届いても、捨てられる。
    ///
    /// ## 戻る時刻は約束しない
    ///
    /// 結果は入力の出来事なので、待ちが終わるのは**届いたフレームの頭**である。`await` が戻る時刻がどの
    /// フレームの境界か、`noLoop()` で止めている間や `render` で届いた結果をどう扱うかは、
    /// ``requestImage(_:)`` と同じく [#2760] と合わせて決めるので、いまの振る舞いであって約束ではない。呼んだ
    /// `Task` を取り消しても待ちは終わらない (取消の扱いも [#2760])。
    ///
    /// **macOS の窓で出す。** iOS・`SketchView` のホストからの出し方と、セキュリティスコープ付きの URL は
    /// [#2604]・[#2605] で決める。選べるのはファイル 1 つで、保存先を選ばせる `selectOutput` やフォルダを選ばせる
    /// `selectFolder` はまだ無い。
    ///
    /// - Parameter prompt: ダイアログに添える文言。
    /// - Returns: 選んだファイルの絶対パス。取り消したら `nil`。走っている実行の外から呼んだら、ダイアログを
    ///   頼まずに `nil` (口ごとに 1 度だけ警告する)。
    ///
    /// [#2760]: https://github.com/mokume-metal/mokume/issues/2760
    /// [#2604]: https://github.com/mokume-metal/mokume/issues/2604
    /// [#2605]: https://github.com/mokume-metal/mokume/issues/2605
    // shot: 撮れない 結果が選んだ人の手元のファイルで、ダイアログは窓の外に出る
    public func selectInput(_ prompt: String) async -> String? {
        guard let selection = LaunchingSketch.selection else {
            OutsideRun.log.warn(.selectInput)
            return nil
        }
        return await selection.request(prompt)
    }
}
