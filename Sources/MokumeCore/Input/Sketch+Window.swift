// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension SketchPart {
    /// ウィンドウの題名を、走っている最中に変える。Processing の `windowTitle()` に当たる。
    ///
    /// ```swift
    /// func mousePressed() {
    ///     windowTitle("clicked \(frameCount)")
    /// }
    /// ```
    ///
    /// 起動のときの題名は ``SketchSettings/title`` で決まり、これはその後に変える。一度呼べば、次に呼ぶまで残る
    /// (`draw()` から毎フレーム呼び直す必要は無い。同じ題名で呼び直しても何も変わらない)。
    ///
    /// ## ウィンドウを持つ所ごとの振る舞い
    ///
    /// - **直に走らせたウィンドウ** (`mokume run`・束ねた `.app`): そのウィンドウの題名が変わる
    /// - **`mokume watch` の下**: ウィンドウは道具が持つので、頼みは絵と一緒に道具へ渡され、**作品のウィンドウ**の題名が
    ///   変わる (プレビューは変わらない)。保存で作り直したスケッチが呼ばなければ、道具が付けた元の題名に戻る
    /// - **``SketchView``**: 何もしない。ウィンドウと題名はホストのアプリのもので、1 度だけ警告する
    /// - **ウィンドウの無い実行** (`mokume render`・参照スケッチの `--render`): 何もせず、止まりもしない
    /// - **走っていないとき** (`init` の中など): 何もせず、1 度だけ警告する
    ///
    /// 絵とフレームの状態には触れない (題名は絵の外にある)。
    ///
    /// - Parameter title: 新しい題名。
    // shot: 撮れない 変わるのはウィンドウの題名で、絵には出ない
    public func windowTitle(_ title: String) {
        liveRuntime()?.requestWindowTitle(title)
    }
}
