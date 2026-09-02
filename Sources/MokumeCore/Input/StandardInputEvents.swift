// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 道具の窓が拾った出来事を、標準入力から受け取る。
///
/// ## なぜ標準入力なのか
///
/// 道具の窓は**内側**にある。`.mokume/input` の区画 ([ADR-0018] 決定 1) は**外から送る
/// 口**で、要求と応答の往復が 1 件ごとにファイルを触る形なので、毎フレームの入力には
/// 向かない。道具は既に子を起こしているので、そこに管が 1 本あれば足りる
/// ([ADR-0032] 決定 4)。
///
/// **面の意味は変えない。** 窓から入る出来事も面から入る出来事も、スケッチから見れば
/// 同じ ``InputState`` に着く。
///
/// ## 塞がずに読む
///
/// 別の流れを立てない — 立てれば錠と隔離を持つことになる ([ADR-0010])。読み口を
/// 塞がない (`O_NONBLOCK`) ようにしてフレームごとに溜まっているぶんだけ引き取る。
/// 素朴に見に行く形で始める ([ADR-0008])。
///
/// ## 合図を増やさない
///
/// 読むのは**共有面へ差し出しているときだけ**である。区画 (`viewport`) の在ることが
/// 既に「見張りから起こされた子」を表しているので ([ADR-0032] 決定 1)、直に走らせた
/// 子の標準入力 (端末) を横取りしないことも同じ合図から従う。**区画を見るのは
/// ``SharedFrameSurface/isEnabled(at:)`` だけ**で、こちらはその答えを受け取る。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class StandardInputEvents {
    /// 一度に読み取る量。
    static let chunkSize = 4096

    /// 行が終わらないまま溜めてよい上限。
    ///
    /// **際限なく伸びないようにする。** 改行を含まないものを流し込まれ続けると、
    /// ここだけが太り続ける。越えたら溜めていたぶんを捨てる — 途中まで読んだ 1 件は
    /// どのみち解けない。
    static let pendingLimit = 1 << 20

    private let descriptor: Int32
    /// まだ行になっていないぶん。
    private var pending = Data()
    /// 解けずに捨てた行の数。**「送ったのに効かない」の切り分けに要る。**
    private(set) var ignored = 0
    /// 受け取った出来事の数。
    private(set) var accepted = 0
    /// 相手が管を畳んだか。畳んだ後は読みに行かない。
    private(set) var isClosed = false

    /// 共有面へ差し出しているときだけ働く。
    ///
    /// **合図を自分では見ない。** 見る場所は ``SharedFrameSurface/isEnabled(at:)`` 1 つに
    /// してある — 経路ごとに合図を持つと、窓は道具のものなのに触っても効かない、という
    /// 片側だけ効いた状態が作れてしまう。
    static func makeIfDriven(
        by isDriven: Bool = SharedFrameSurface.isEnabled(),
        descriptor: Int32 = FileHandle.standardInput.fileDescriptor
    ) -> StandardInputEvents? {
        isDriven ? StandardInputEvents(descriptor: descriptor) : nil
    }

    init(descriptor: Int32) {
        self.descriptor = descriptor
        // **塞がないようにする。** これを忘れると、次の 1 件が来るまでフレームが進まない
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    /// 溜まっているぶんを引き取って、合流点へ流す。
    func drain(into state: InputState) {
        readAvailable()
        while let line = takeLine() {
            guard let event = Self.event(from: line) else {
                ignored += 1
                continue
            }
            state.enqueue(event)
            accepted += 1
        }
    }

    /// いま読めるだけ読む。**待たない。**
    private func readAvailable() {
        guard !isClosed else { return }
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                // **溜まりすぎたら捨てる。** 途中まで読んだ 1 件はどのみち解けない
                if pending.count > Self.pendingLimit {
                    pending.removeAll(keepingCapacity: false)
                    ignored += 1
                }
                continue
            }
            // 0 は相手が畳んだ合図。負は「いまは無い」(EAGAIN) か、読めない相手
            if count == 0 { isClosed = true }
            return
        }
    }

    /// 溜まっているぶんから 1 行取り出す。**改行が来るまでは取り出さない** — 半分だけ
    /// 届いた行を解こうとすると、その 1 件が消えるうえに次の行の頭を食う。
    private func takeLine() -> Data? {
        guard let index = pending.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = Data(pending[pending.startIndex..<index])
        pending = Data(pending[pending.index(after: index)...])
        return line
    }

    /// 1 行を出来事にする。**知らない種別も、壊れた行も、その 1 件だけ捨てる**
    /// ([ADR-0018] 決定 3)。
    private static func event(from line: Data) -> InputEvent? {
        guard !line.isEmpty, let raw = try? JSONDecoder().decode(RawInputEvent.self, from: line)
        else { return nil }
        return raw.event
    }
}
