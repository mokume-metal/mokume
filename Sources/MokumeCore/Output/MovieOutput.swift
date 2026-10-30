// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 動きを 1 本のファイルへ書く書き手が揃える口 ([#2440])。
///
/// ``MovieWriter`` はこの口の向こうの、1 本の仕事 (順番・背圧・終わりの待ち) だけを持つ。
/// ``MovieFile`` (ProRes 4444 の `.mov` と、配る形の H.264 の `.mp4`) と ``GIFFile`` (配る形の
/// `.gif`) が同じ口で書くので、順番・背圧・閉じる待ちを 3 つに写さない。
///
/// 隔離の外で、1 本の仕事だけが触る。
///
/// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
nonisolated protocol MovieOutput: AnyObject {
    /// 1 枚を書き足す。**時刻はフレーム自身のもの。**
    func append(_ image: DisplayImage, at time: Double) async throws(MovieWriteFailure)
    /// 音の 1 窓を書き足す ([#3125])。**音声トラックを持たない書き手 (GIF・配る形の MP4) は何もしない。**
    ///
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    func appendSound(_ window: SoundWindow) async throws(MovieWriteFailure)
    /// 書き終える。**ファイルが閉じてから返る。** `lastFrameAt` は最後のフレームの時刻。
    func finish(lastFrameAt time: Double) async throws(MovieWriteFailure)
    /// 書き損じた録りを捨てる ([#3426])。**書いている最中のファイルを取り消し、一時ファイルを消す。行き先に前からあった
    /// ファイルには触れない。** ``finish(lastFrameAt:)`` の代わりに呼び、呼んだ後は何も書かない。
    ///
    /// [#3426]: https://github.com/mokume-metal/mokume/issues/3426
    func abandon()
}

extension MovieOutput {
    func appendSound(_ window: SoundWindow) async throws(MovieWriteFailure) {}
    /// 書き手が取り消す物を持たないとき (検査の替え玉) は何もしない。
    nonisolated func abandon() {}
}
