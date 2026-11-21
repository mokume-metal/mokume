// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// `swift build` が出す段数の行 (`[19 / 24]`・`[12/345] Compiling …`) の読み (#4121)。
///
/// **分母は途中で増える** (Swift Build は計画を先送りした分を後から足す)。だから割合にせず、
/// 段数のまま見せる。
nonisolated struct BuildProgress: Equatable, Sendable {
    /// 済んだ段の数。
    let done: Int
    /// いま分かっている段の数。
    let total: Int

    /// 行の頭の `[n / m]` を読む。**`0 < total`・`done <= total` を満たさない行は読まない。**
    ///
    /// Swift Build の `[19 / 24]` と、旧ビルドシステムの `[12/345] Compiling …` の両方を読む。
    /// `[Planning deferred tasks]` のような数字でない括弧は読まない。
    static func parse(_ line: some StringProtocol) -> BuildProgress? {
        var rest = Substring(line)
        guard rest.first == "[" else { return nil }
        rest = rest.dropFirst()
        guard let done = leadingNumber(&rest) else { return nil }
        rest = rest.drop(while: { $0 == " " })
        guard rest.first == "/" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " })
        guard let total = leadingNumber(&rest), rest.first == "]" else { return nil }
        guard total > 0, done <= total else { return nil }
        return BuildProgress(done: done, total: total)
    }

    private static func leadingNumber(_ text: inout Substring) -> Int? {
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        text = text.dropFirst(digits.count)
        return value
    }
}

/// 管から来た断片を、完結した行に割る。
///
/// **行の途中で割れた断片は次の断片まで持つ。** 割るのはバイトの `\n`・`\r` で、UTF-8 の
/// 文字の途中では割れない (どちらも多バイト文字の中に現れない)。
nonisolated struct LineSplitter {
    private var pending = Data()

    /// 断片を足し、完結した行を返す。空の行は返さない。
    mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var start = pending.startIndex
        for index in pending.indices where pending[index] == 0x0A || pending[index] == 0x0D {
            if index > start { lines.append(String(decoding: pending[start..<index], as: UTF8.self)) }
            start = pending.index(after: index)
        }
        pending = Data(pending[start...])
        return lines
    }

    /// 終わりに残った、改行で閉じていない行。
    mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// 作り直しの糸から main actor へ段数を届ける口。
///
/// **届けるのは最新の値だけで、main に積む配達は 1 つまで。** 大きなビルドは段数の行を
/// 1 秒に何百も出すので、行ごとに積むと main が溢れる。配達は積んだ順に走る
/// (`DispatchQueue.main`) ので、作り直しの終わりより後に前の値が届くことはない。
///
/// `@unchecked Sendable` の根拠は鍵で、`latest` と `scheduled` は `lock` の中でだけ触る。
/// 受け手 (`deliver`) は main actor でだけ読み書きする。
nonisolated final class BuildProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: BuildProgress?
    private var scheduled = false
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// 受け手。作り直しの糸から直接は呼ばない。
    @MainActor var deliver: (BuildProgress) -> Void = { _ in }

    /// - Parameter schedule: main actor で走らせる口。**検査だけが差し替える。**
    init(
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        }
    ) {
        self.schedule = schedule
    }

    /// 段数を置く。どの糸から呼んでもよい。
    func post(_ progress: BuildProgress) {
        let needsDelivery = lock.withLock {
            latest = progress
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard needsDelivery else { return }
        schedule { MainActor.assumeIsolated { self.flush() } }
    }

    @MainActor private func flush() {
        let progress = lock.withLock {
            defer {
                latest = nil
                scheduled = false
            }
            return latest
        }
        if let progress { deliver(progress) }
    }
}
