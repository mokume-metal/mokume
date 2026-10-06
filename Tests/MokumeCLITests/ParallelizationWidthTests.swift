// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

/// 検査の並列の幅が、**渡した値どおりに守られている**か
/// ([#2055](https://github.com/mokume-metal/mokume/issues/2055))。
///
/// `scripts/gpu-slot.py` は、子の `swift test` へ
/// `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` を渡して、1 プロセスの中で同時に進む
/// 検査の数を縛っている (既定は 1。理由は同スクリプトの冒頭「並列の幅」・#1999・#2007)。
/// その口の名前には `EXPERIMENTAL` が付いていて、toolchain の更新で名前が変われば、
/// Swift Testing は知らない変数を読まないので、縛りは**黙って**外れる。外れたことに気付く
/// 手段が、専用機の `render` が確率的に赤くなるのを人が読み取ることだけだったので、
/// ここで実際の同時数を数える。
///
/// **数え方**: 引数つきの検査の各ケースが、共有のカウンタを上げてから短く眠り、起きたら
/// 下げる。眠っている間に次のケースが始まれば、カウンタはその分だけ上がる。各ケースは
/// 上げた直後に「いまの同時数 ≤ 渡した幅」を表明するので、最大が確定するのを待たずに、
/// 越えた瞬間のケースが赤になる。検査はこのターゲットの既定の隔離 (`Package.swift` の
/// `.defaultIsolation(MainActor.self)`) で main actor に載るが、眠りで suspend するので、
/// 幅が外れていればケースは main actor の上で互いに重なる (数え合いに競合は無い)。
///
/// **幅の環境変数が無い実行 (素の `swift test`) では飛ぶ。** 幅を縛らない実行で同時数を
/// 見ても、何も言えないからである。
///
/// GPU は使わない (`RenderDevice` を作らない)。所要は、幅 1 でケースが 1 本ずつ進むとき
/// `cases × napMilliseconds` = 0.6 秒ほどである。
@Suite("検査の並列の幅")
struct ParallelizationWidthTests {
    /// Swift Testing が並列の幅を読む環境変数。`scripts/gpu-slot.py` の
    /// `PARALLELIZATION_WIDTH_VARIABLE` と同じ名前でなければならない。
    nonisolated static let variable = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"

    /// 渡された幅の綴り。空白だけの値は、`gpu-slot.py` と同じく持っていないものとして扱う。
    nonisolated static let spelledWidth: String? = {
        guard let value = ProcessInfo.processInfo.environment[variable],
            !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }()

    /// ケースの数。幅 1 のとき 2 つ以上が重なれば赤、を見るので、幅の既定 (1) と以前の
    /// 値 (16 → 同時の発行口は 12 本) を区別できるだけあればよい。
    nonisolated static let cases = 12

    /// 各ケースが眠る長さ。重なりを観測するための窓で、幅が外れていれば全ケースがこの
    /// 間に起動する。
    static let napMilliseconds = 50

    /// いま進んでいるケースの数。main actor の上でだけ読み書きする。
    static var inFlight = 0

    @Test(
        "同時に進むケースの数が、渡した幅を越えない",
        .enabled(
            if: spelledWidth != nil,
            "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH を渡した実行 (gpu-slot.py 経由) でだけ見る"),
        arguments: 0..<cases)
    func concurrentCasesStayWithinTheWidth(_ index: Int) async throws {
        let spelled = try #require(Self.spelledWidth)
        // 幅として読めない値 (1 以上の整数でない) を渡された実行では、縛りが効いているかを
        // 比べる相手が無い。渡す側の誤りなので、飛ばさずに赤にする
        let width = try #require(
            Int(spelled).flatMap { $0 >= 1 ? $0 : nil },
            "\(Self.variable)=\(spelled) は Swift Testing の読む幅 (1 以上の整数) ではない")

        Self.inFlight += 1
        defer { Self.inFlight -= 1 }
        #expect(
            Self.inFlight <= width,
            """
            ケース \(index) の起動時に \(Self.inFlight) 個のケースが同時に進んでいる (渡した幅は \(width))。\
            Swift Testing が \(Self.variable) を読んでいない — toolchain の \
            Testing の文字列から今の口の名前を引き、scripts/gpu-slot.py を直す
            """)
        try await Task.sleep(for: .milliseconds(Self.napMilliseconds))
    }
}
