// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 別のプロセスが差し出している絵を、**作品の窓**として出す。
///
/// ## なぜ道具が窓を持つのか
///
/// 見張り (`watch`) は保存のたびに子を入れ替えるので、**子が窓を持つ限り窓は死ぬ**。
/// 全画面と、どの画面に置いたかは窓の寿命に紐づいているので、作り直しのたびに一緒に
/// 失われる — 位置を覚えて開き直しても戻らない。見張りから起こした作品も本番になりうる
/// 以上、これは**本番の見え方が保存のたびに壊れる**ということである
/// ([ADR-0032] 決定 1)。
///
/// ## ここに道具の都合を出さない
///
/// つまみも、作り直しの状態も、回っている印も載せない — 見張りから本番を回している間、
/// 開発の都合が本番の画面に出てはならない ([ADR-0032] 決定 1・6)。それらは
/// ``SharedFramePreview`` の仕事である。
///
/// **守り方は「載せないように気をつける」ではない。** 重ねる面を台へ渡さないので、
/// 載せる場所そのものが無い。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
public final class SharedFrameWindow {
    private let stage: SharedFrameStage

    /// - Parameters:
    ///   - facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    ///   - title: 窓の名前。
    public init(gpu: RenderDevice, facet: URL, title: String) throws(RenderFailure) {
        self.stage = try SharedFrameStage(
            gpu: gpu, facet: facet,
            look: SharedFrameStage.Look(
                title: title, autosaveName: WindowPlacement.autosaveName,
                defaultSize: NSSize(width: 480, height: 270)))
    }

    /// 窓を出し、区画を見張り始める。
    public func open() {
        stage.open()
    }

    /// 畳む。
    public func close() {
        stage.close()
    }
}
