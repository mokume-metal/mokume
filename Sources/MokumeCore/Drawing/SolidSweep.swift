// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 裏面が絵に出うる置き場所の、裏 → 表の描き方を畳む ([#1947])。
///
/// 立体の列は、置き場所ごと・部品ごとに裏 → 表の 2 回 (`.front` を捨てる → `.back` を捨てる) で
/// 描く (``Canvas/Batch/backFaceParts``)。そのまま積むと描く呼び出しが置き場所の数に比例する
/// (10 万か所で 20 万回)。捨て方は描く呼び出しごとの状態なので、置き場所 1 つに 1 つの描く呼び出しでは
/// 畳めない。
///
/// **畳み方: 捨て方を `.back` に固定し、`.front` を捨てる描画を「三角形の 2 点目と 3 点目を入れ替えた
/// 写し」の描画に置き換える。** 巻き方を入れ替えた三角形は、元の三角形が裏向きのときだけ表向きになる
/// ので、`.back` を捨てる描画で残るのは元が `.front` を捨てる描画で残るものと同じ三角形である。
/// 置き場所 1 つぶんの描画 (部品・部品の外の区間を記録した順に、裏の面 → 表の面) を 1 本の添字の列に
/// 並べ、置き場所の連なりを 1 回のインスタンス描画で描く。**1 つのインスタンス描画は、置き場所 k の添字の
/// 列を描き切ってから k + 1 に移る**ので、置き場所どうし・部品どうしの順は呼び出し順のままである
/// (ADR-0021 決定 2 の追補)。置き場所を裏の列と表の列に並べ直す案は、奥から並べた 2 つの半透明の形で
/// 奥の形の手前の面を手前の形の裏面が捨てるので採らない。
///
/// **添字の列にすると、同じ値の頂点を同じ番号で指せる** (``SolidVertexSharing``)。組み込みの形を記録した
/// 形は三角形ごとに 3 点を持つが、同じ値の頂点は 1 つに寄せる。写しを足すと添字の数は 2 倍になるが、
/// 頂点関数が走る数は寄せたぶん減り、GPU の時間も置き場所ごとに描くときより短い (数字は
/// ``SolidVertexSharing``)。
///
/// **形から求めた向きを持つ頂点 (法線を書いていないモデル) は、写しで向きを裏返す** ([#2222])。断片は、
/// 求めた向きの面が裏を向いていれば (`front_facing` が裏) 向きを裏返して光を当てる。写しは元が裏を
/// 向いているときだけ表を向いて残るので、断片は裏返さない。そこで写しの三角形が指すそうした頂点の
/// 添字に印 (``flipsNormal``) を立て、頂点関数 (`solidVertexMain`) が向きを裏返して出す。元を置き場所ごとに
/// 描いたとき断片が裏返すのと同じ向きになり、光の当たり方は変わらない。
///
/// **畳まないもの** (置き場所ごとに描く):
/// - 置き場所が少ない連なり。省ける呼び出しより添字の列を組む費用が高い (``paysOff(instances:passes:programLength:vertices:)``)。
/// - 写しにする三角形の 3 点で、向きを形から求めたかが揃わない形 (一部の頂点にだけ `normal()` を書いた
///   `beginShape` の形など)。断片は 3 点の間で補間した印で裏返すので、頂点ごとの印では合わせられない。
/// - 頂点を自分の置き場から読む列 (GPU が持つモデル) と、引数を GPU が書く列 (粒)。
///
/// この型が持つのは GPU に触れない部分 (連なりの割り方・描く順・添字の列の組み立て・使う判定)。添字の列を
/// 組んで置き場へ写すのは ``Canvas/uploadSweeps()``、描くのは `Canvas.encodeBackThenFront` である。
///
/// [#1947]: https://github.com/mokume-metal/mokume/issues/1947
/// [#2222]: https://github.com/mokume-metal/mokume/issues/2222
enum SolidSweep {
    /// 描き方の違う置き場所の連なり。
    struct Run: Equatable {
        /// 連なりの描き方。
        enum Kind: Equatable {
            /// 部品に印の立つ置き場所が無い。列の捨て方で 1 回で描く (続けて並んだものは 1 回の呼び出し)。
            case plain
            /// 置き場所の印によらず立つ部品だけを、裏 → 表で描く。
            case someParts
            /// 全部の部品を、裏 → 表で描く (置き場所に印が付いている、または全部の部品がいつも立つ)。
            case allParts
        }
        /// 列の中での置き場所の番号 (列の先頭から数える)。
        var instances: Range<Int>
        var kind: Kind
    }

    /// 裏 → 表で描く部品の、描く側が読める分。
    ///
    /// 列の区間の中に収まり、列と同じ数え方 (添字の有無) の空でない部品だけを、記録した順に持つ。
    struct Parts: Equatable {
        /// 列全体の描く単位での区間 (添字の列なら読む順の並び、そうでなければ頂点の並び)。
        let whole: Range<Int>
        /// 使える部品。
        private(set) var all: [SolidPart] = []
        /// 置き場所の印によらず立つ部品 (``SolidPart/showsBackFaces``)。
        private(set) var alwaysShown: [SolidPart] = []

        init(run: Shape.Run, backFaceParts: [SolidPart]) {
            self.init(
                whole: run.isIndexed
                    ? run.indexStart..<(run.indexStart + run.indexCount)
                    : run.start..<(run.start + run.count),
                isIndexed: run.isIndexed, backFaceParts: backFaceParts)
        }

        /// - Parameters:
        ///   - whole: 列全体の描く単位での区間。
        ///   - isIndexed: 列が添字で読むか。部品の数え方 (``SolidPart/isIndexed``) と合うものだけを持つ。
        init(whole: Range<Int>, isIndexed: Bool, backFaceParts: [SolidPart]) {
            self.whole = whole
            for part in backFaceParts
            where part.isIndexed == isIndexed && !part.range.isEmpty
                && whole.contains(part.range.lowerBound) && part.range.upperBound <= whole.upperBound
            {
                all.append(part)
                if part.showsBackFaces { alwaysShown.append(part) }
            }
        }

        /// 置き場所 1 つが、裏 → 表で描く部品。印があれば全部、無ければいつも立つものだけ。
        func shown(marked: Bool) -> [SolidPart] { marked ? all : alwaysShown }

        /// 連なりの描き方で立つ部品。
        func shown(for kind: Run.Kind) -> [SolidPart] {
            switch kind {
            case .plain: []
            case .someParts: alwaysShown
            case .allParts: all
            }
        }
    }

    /// 置き場所を、描き方の同じ連なりに割る。
    ///
    /// - Parameters:
    ///   - instanceCount: 列の置き場所の数。
    ///   - marks: 裏面が絵に出うる置き場所の番号 (``Canvas/Batch/backFaceInstances``・置いた順の昇順)。
    ///     範囲の外の番号は読み飛ばす。
    ///   - parts: 描く側が読める部品。
    ///
    /// 印のある置き場所は全部の部品を、無い置き場所はいつも立つ部品だけを立てる。全部の部品がいつも
    /// 立つ列は、印の有無で描き方が変わらないので、印で連なりを割らない。連なりの数は、印の付いた置き場所が
    /// 続く塊の数に比例する (置き場所の数ではない)。
    static func runs(instanceCount: Int, marks: [Int], parts: Parts) -> [Run] {
        guard instanceCount > 0 else { return [] }
        func kind(of shown: [SolidPart]) -> Run.Kind {
            shown.isEmpty ? .plain : (shown.count == parts.all.count ? .allParts : .someParts)
        }
        let marked = kind(of: parts.shown(marked: true))
        let unmarked = kind(of: parts.shown(marked: false))
        if marked == unmarked || marks.isEmpty {
            return [Run(instances: 0..<instanceCount, kind: marks.isEmpty ? unmarked : marked)]
        }
        // 置いた順に並んでいるはずだが、並んでいなくても同じ連なりになるよう整える
        let ordered = isAscending(marks) ? marks : marks.sorted()
        var runs: [Run] = []
        var cursor = 0
        var index = 0
        while index < ordered.count {
            guard ordered[index] >= 0 else {
                index += 1
                continue
            }
            let first = max(ordered[index], cursor)
            guard first < instanceCount else { break }
            var end = first + 1
            index += 1
            while index < ordered.count, ordered[index] <= end {
                end = max(end, ordered[index] + 1)
                index += 1
            }
            end = min(end, instanceCount)
            guard end > first else { continue }
            if first > cursor { runs.append(Run(instances: cursor..<first, kind: unmarked)) }
            runs.append(Run(instances: first..<end, kind: marked))
            cursor = end
        }
        if cursor < instanceCount { runs.append(Run(instances: cursor..<instanceCount, kind: unmarked)) }
        return runs
    }

    /// 昇順 (同じ値を含む) に並んでいるか。
    private static func isAscending(_ numbers: [Int]) -> Bool {
        var previous = Int.min
        for number in numbers {
            if number < previous { return false }
            previous = number
        }
        return true
    }

    /// 置き場所 1 つを描く、捨て方つきの区間。**この順に描く** (部品・部品の外の区間を記録した順に、
    /// 部品は裏の面 → 表の面)。
    struct Pass: Equatable {
        var range: Range<Int>
        var cull: MTLCullMode
    }

    /// 置き場所 1 つを描く区間を、描く順に並べる。
    ///
    /// 部品の外の区間と立っていない部品は列の捨て方 (`plainCull`) で 1 回、立っている部品は
    /// `.front` → `.back` (内向きなら `.back` → `.front`) の 2 回で描く。表の巻き方は列が決めてある
    /// (``Canvas/Batch/frontFacing``) ので、`.front` を捨てれば裏の面、`.back` を捨てれば表の面になる。
    static func passes(whole: Range<Int>, shown: [SolidPart], plainCull: MTLCullMode) -> [Pass] {
        var passes: [Pass] = []
        var cursor = whole.lowerBound
        for part in shown {
            if part.range.lowerBound > cursor {
                passes.append(Pass(range: cursor..<part.range.lowerBound, cull: plainCull))
            }
            for cull in part.insideOut ? [MTLCullMode.back, .front] : [.front, .back] {
                passes.append(Pass(range: part.range, cull: cull))
            }
            cursor = part.range.upperBound
        }
        if cursor < whole.upperBound {
            passes.append(Pass(range: cursor..<whole.upperBound, cull: plainCull))
        }
        return passes
    }

    // MARK: - 添字の列

    /// 添字の列 1 本の長さ。`passes` を `.back` 固定で描く添字の数。
    ///
    /// 三角形 (3 点で 1 枚) ごとに数え、3 つ揃わない端は読まない。捨てない区間 (`.none`) は、三角形ごとに
    /// 元と写しの 2 枚が並ぶので 2 倍になる。
    static func programLength(of passes: [Pass]) -> Int {
        var length = 0
        for pass in passes {
            let corners = pass.range.count / 3 * 3
            length += pass.cull == .none ? corners * 2 : corners
        }
        return length
    }

    /// 写しで向きを裏返す頂点の印。添字の最上位の桁で、`Shapes.metal` の `kSolidFlipsNormal` と同じ値
    /// ([#2222])。
    ///
    /// 頂点の表 (``appendProgram(_:indices:vertexBase:vertices:to:)`` の `vertices`) では、形から求めた向きを
    /// 持つ頂点の番号に立てておく。添字の列には**写しの三角形にだけ**残し、元の三角形からは外して足す。
    /// 頂点関数は桁を外した番号の頂点を読み、桁が立っていれば向きを裏返して出す。
    ///
    /// [#2222]: https://github.com/mokume-metal/mokume/issues/2222
    static let flipsNormal: UInt32 = 1 << 31

    /// `passes` を描く順に、`.back` 固定で描く添字の列を `output` の後ろへ足す。
    ///
    /// 区間の中の三角形は、`.back` を捨てる区間なら元のまま、`.front` を捨てる区間なら 2 点目と
    /// 3 点目を入れ替えた写しにして足す。捨てない区間 (`.none`) は、三角形ごとに [元, 写し] の対を足す — 元と
    /// 写しは巻き方が逆なので、どちらか一方だけが残り、三角形どうしの順は変わらない。
    ///
    /// **元の三角形の添字からは ``flipsNormal`` を外し、写しの三角形の添字には表のまま残す。** 写しは元が
    /// 裏を向いているときだけ表を向いて残るので、形から求めた向きの頂点は写しの側で向きを裏返す
    /// (``SolidSweep``)。印の無い頂点 (書かれた向き) の写しは、元と同じ添字を指す。
    ///
    /// - Parameters:
    ///   - passes: 描く区間 (``passes(whole:shown:plainCull:)``)。
    ///   - indices: 区間が添字の列を指すなら、その並び (`solidIndices`)。頂点の並びを指すなら `nil` で、
    ///     区間の位置がそのまま頂点の番号になる。
    ///   - vertexBase: `vertices` の先頭の頂点の番号。
    ///   - vertices: 頂点ごとの、描くときに使う番号 (`vertexBase` からの並び)。同じ値の頂点を 1 つの番号へ
    ///     寄せる (``SolidVertexSharing``)。**形から求めた向きを持つ頂点は ``flipsNormal`` を立てる**。
    ///
    /// - Returns: 描ける形なら真。表の外の頂点を 1 つでも指したとき、写しにする三角形の 3 点で
    ///   ``flipsNormal`` が揃わないときは偽 (`output` は不定)。断片は 3 点の間で補間した印で向きを裏返すので、
    ///   揃わない三角形の写しは、頂点ごとの印では元と同じ光の当たり方にできない。写しにしない三角形
    ///   (`.back` を捨てる区間) は揃わなくても描ける。
    static func appendProgram(
        _ passes: [Pass], indices: [UInt32]?, vertexBase: Int, vertices: [UInt32],
        to output: inout [UInt32]
    ) -> Bool {
        output.reserveCapacity(output.count + programLength(of: passes))
        let number = ~flipsNormal
        for pass in passes {
            let triangles = pass.range.count / 3
            for triangle in 0..<triangles {
                let position = pass.range.lowerBound + triangle * 3
                let raw: (Int, Int, Int)
                if let indices {
                    guard position >= 0, position + 2 < indices.count else { return false }
                    raw = (Int(indices[position]), Int(indices[position + 1]), Int(indices[position + 2]))
                } else {
                    raw = (position, position + 1, position + 2)
                }
                let local = (raw.0 - vertexBase, raw.1 - vertexBase, raw.2 - vertexBase)
                guard
                    local.0 >= 0, local.0 < vertices.count, local.1 >= 0, local.1 < vertices.count,
                    local.2 >= 0, local.2 < vertices.count
                else { return false }
                let (first, second, third) = (vertices[local.0], vertices[local.1], vertices[local.2])
                // 写しにする三角形は、3 点で印が揃っていなければならない
                let flipsAlike = (first ^ second) & flipsNormal == 0 && (first ^ third) & flipsNormal == 0
                // 配列を作らず 1 つずつ足す (1 枚ごとに確保しない)
                switch pass.cull {
                case .back:
                    output.append(first & number)
                    output.append(second & number)
                    output.append(third & number)
                case .front:
                    guard flipsAlike else { return false }
                    output.append(first)
                    output.append(third)
                    output.append(second)
                default:
                    guard flipsAlike else { return false }
                    output.append(first & number)
                    output.append(second & number)
                    output.append(third & number)
                    output.append(first)
                    output.append(third)
                    output.append(second)
                }
            }
        }
        return true
    }

    // MARK: - 使う判定

    /// 描く呼び出し 1 回の費用を、添字 1 つを組んで写す費用の何倍とみるか。
    ///
    /// 描く呼び出し 1 回 (`setCullMode` を含む) は 65 ns ほどで (10 万か所で 20 万回 = 約 13 ms)、添字を
    /// 1 つ組んで写す費用は 1 ns ほどである (release・Apple M3 Max の実測)。
    static let indicesPerCall = 64

    /// 頂点 1 つを調べて同じ値の頂点へ寄せる費用 (``SolidVertexSharing``) を、添字 1 つを組んで写す費用の
    /// 何倍とみるか。頂点 1 つで 8〜10 ns ほど (同じ実測)。
    static let indicesPerVertex = 10

    /// 連なり 1 つを、添字の列にして 1 回で描くか。
    ///
    /// 置き場所の数 × 描く呼び出し (`passes` の数) で省ける呼び出しが、添字の列を組む費用 (写す添字の数と、
    /// 頂点を調べる数) に見合うときだけ使う。置き場所が少ない連なり・大きな形を数か所に置いた連なりでは、
    /// 組む費用のほうが高い。
    ///
    /// - Parameters:
    ///   - instances: 連なりの置き場所の数。
    ///   - passes: 置き場所 1 つを描く区間の数 (描く呼び出しの数)。
    ///   - programLength: 添字の列の長さ (``programLength(of:)``)。
    ///   - vertices: 調べる頂点の数 (列の頂点の数)。
    static func paysOff(instances: Int, passes: Int, programLength: Int, vertices: Int) -> Bool {
        instances * passes * indicesPerCall >= programLength + vertices * indicesPerVertex
    }
}

/// 連なりを添字の列で描く判定の方針 (``Canvas/sweepPolicy``)。
enum SolidSweepPolicy: Equatable {
    /// 省ける呼び出しが費用に見合う連なりだけ、添字の列で描く。
    case automatic
    /// 添字の列で描かない (置き場所ごとに描く)。
    case never
    /// 描ける連なりは、小さくても添字の列で描く。
    case always
}
