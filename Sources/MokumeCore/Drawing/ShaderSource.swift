// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 断片を、そのままコンパイルできる 1 本の原稿へ組み立てる。
///
/// ## 前置きは無条件に足す
///
/// 「断片が既に宣言を持っていれば足さない」という条件分岐は作らない。**コメントに
/// 書かれた宣言にまで反応して絵が消える**からで、二重に足されても壊れない形にする
/// ほうが安全である。
///
/// ## 並び
///
/// 値の宣言 → 面の宣言 → 共通部分 → 断片。共通部分が値と面の型を使い、断片が共通部分の
/// 型を使うので、この順序でしか組み立てられない。区切りはそれぞれ頭で名前を名乗る
/// (``assemble(prelude:values:surfaces:body:)``)。
enum ShaderSource {
    /// 断片をファイルから読む。**塗り・効果・計算で 1 つ** ([#895])。
    ///
    /// 探す場所は貼る絵と同じ並び (``ImageFile/candidates(for:)``)。**ただし見張りの下では、置き場の
    /// 断片だけ束の写しより先に置き場の元を探す** (``ShaderOrigin``・[#2517])。名前は拡張子を
    /// 落としたファイル名で、計算ではこれが**断片の中の入口の関数の名前**にもなる。
    ///
    /// 3 者が同じ 7 行を持っていたので畳んだ — 候補の探し方が割れると、「読めない」が
    /// 断片の種類によって別の理由で出るようになる。
    ///
    /// **見つかったものを「見つからない」と名乗らない** ([#2358])。中身は ``body(at:path:)`` が読む。
    ///
    /// [#895]: https://github.com/mokume-metal/mokume/issues/895
    /// [#2517]: https://github.com/mokume-metal/mokume/issues/2517
    /// [#2358]: https://github.com/mokume-metal/mokume/issues/2358
    static func read(
        at path: String, origin: URL? = ShaderOrigin.startup(),
        candidates find: ((String) -> [URL])? = nil
    ) throws(ShaderFailure) -> (url: URL, body: String, name: String) {
        // 見張りの下では、置き場の断片は束の写しではなく元のファイルへ解く (#2517)
        // **既定は他の口と同じ探し方** (包みを数えられなかった置き場も受ける・#2838)。検査は並びを差し替える
        let search = find.map { AssetLookup.Search(places: $0(path)) } ?? ImageFile.search(for: path)
        let candidates = ShaderOrigin.inserting(origin: origin, for: path, into: search.places)
        let url: URL
        do {
            url = try AssetLookup.locate(candidates, unlistable: search.unlistable, path: path)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            case .unreachable(let path, let location, let reason):
                throw .unopenable(
                    path: path, location: location, reason: AssetOpening.unreachableReason(reason))
            }
        }
        return (url, try body(at: url, path: path), url.deletingPathExtension().lastPathComponent)
    }

    /// 場所が分かった断片の中身を読む。保存を拾って読み直す経路 (``ShaderBox``) もここを通す。
    ///
    /// **読めなかった事情を落とさない** ([#2358])。ディレクトリや読む権利の無いファイルは
    /// ``ShaderFailure/unopenable(path:location:reason:)`` で、解けた場所と OS の事情を名乗る。
    /// 開けたが UTF-8 の文字でない中身 (Shift_JIS で保存した断片など) は
    /// ``ShaderFailure/unreadable(path:)`` で、UTF-8 で保存し直すよう言う。どちらも、資源の宣言を
    /// 確かめよという助言 (見つからないとき) は出さない。
    static func body(at url: URL, path: String) throws(ShaderFailure) -> String {
        if let refusal = AssetOpening.refusal(at: url) {
            throw .unopenable(path: path, location: refusal.location, reason: refusal.reason)
        }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw .unreadable(path: path)
        }
        return body
    }

    /// `values:`・`surfaces:` の名前が、断片の中で `values.<名前>`・`surfaces.<名前>` と書ける字の並びか
    /// ([#2783])。
    ///
    /// 受けるのは、文字か `_` で始まり、文字・数字・`_` が続く空でない名前。**ASCII の外の文字も
    /// 受ける** — Metal は `波` を識別子として通すので、ASCII に絞ると今組める名前を断る。判定は
    /// C++ の識別子と同じ Unicode の XID_Start / XID_Continue で引く。
    ///
    /// 字の並びが通っても Metal で使えない名前 (予約語・組み込みの型・前置きのマクロ) は、表を
    /// 持たずに組み立ての誤りから言い直す (``DeclaredNames``)。
    ///
    /// [#2783]: https://github.com/mokume-metal/mokume/issues/2783
    static func isUsableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || first.properties.isXIDStart else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy { $0.properties.isXIDContinue }
    }

    /// `values:`・`surfaces:` の名前のうち、字の並びが書けないものを名指しする理由 ([#2783])。
    /// 1 つも無ければ `nil`。
    ///
    /// **組み立てに任せない。** 名前は宣言 (`declaration(of:)`) へそのまま書かれるので、
    /// `tint color` は本体の前置きの名 (`mokume/Values:2:15: error: …`) で出て、直す先が Swift の
    /// 引数だと分からない。空の名前と `;` を含む名前はそもそも誤りにならず、宣言の欄と詰める値
    /// (``pack(_:)``) がずれたまま組み上がって、断片が別の値を読む。
    ///
    /// 呼ぶのは利用者の断片を組む唯一の口 (`ShaderLibraries` の利用者の断片の仕事) で、組み立ての
    /// 前に断る。行の形は入口の言い直し (``ShaderEntryPoint``) と同じ `<断片の名前>: error: …`。
    ///
    /// [#2783]: https://github.com/mokume-metal/mokume/issues/2783
    static func unusableNames(
        values: [String: ShaderValue], surfaces: [String: ShaderSurface] = [:], in fragment: String
    ) -> String? {
        let unusable =
            values.keys.filter { !isUsableName($0) }.sorted().map { ("values:", "values", $0) }
            + surfaces.keys.filter { !isUsableName($0) }.sorted().map { ("surfaces:", "surfaces", $0) }
        guard !unusable.isEmpty else { return nil }
        return unusable.map { argument, prefix, name in
            "\(oneLine(fragment)): error: the name \(name.debugDescription) in \(argument) cannot be "
                + "read in the fragment as \(prefix).<name>. A name has to start with a letter or an "
                + "underscore and hold only letters, digits and underscores, so rename it where you "
                + "pass \(argument)"
        }.joined(separator: "\n")
    }

    /// 宣言の 1 行と、その行に書いた名前 (名前を書かない行は `nil`)。
    typealias DeclarationLine = (text: String, name: String?)

    /// 値の宣言の行。1 行目が `struct Values {` で、名前の行は ``pack(_:)`` と同じ並び。
    static func declarationLines(of values: [String: ShaderValue]) -> [DeclarationLine] {
        let sorted = packingOrder(of: values)
        // 空の構造体は大きさが処理系任せになるので、必ず 1 つは入れておく
        let fields: [DeclarationLine] =
            sorted.isEmpty
            ? [("    float4 mokume_unused;", nil)]
            : sorted.map { ("    \($0.value.declaredType) \($0.key);", $0.key) }
        return [("struct Values {", nil)] + fields + [("};", nil)]
    }

    /// 値の名前と、その形。
    ///
    /// 名前は**断片の中でそのまま書ける識別子**になる (字の並びは組み立ての前に
    /// ``unusableNames(values:surfaces:in:)`` が検め、Metal で使えない名前は ``DeclaredNames`` が
    /// 言い直す)。並べる順は名前順に固定する
    /// (辞書の順序に依らせると、同じ断片が実行のたびに別の原稿になる)。
    static func declaration(of values: [String: ShaderValue]) -> String {
        declarationLines(of: values).map(\.text).joined(separator: "\n") + "\n"
    }

    /// 値を詰める並び (= 宣言する並び)。**宣言と詰め方が別々に動かないよう、ここで 1 か所に決める。**
    ///
    /// Metal の構造体での大きさ (``ShaderValue/byteSize``) の降順で、同じ大きさなら名前の降順。
    /// 大きさは 64・16・8・4・1 バイトのどれかで、どれも前の大きさの約数であり、置く境界
    /// (`float3`・`float4`・`float4x4` は 16、`float2` は 8) は大きさ以下である。**大きいものから
    /// 並べれば、各値は自分の境界にちょうど載り、境界に揃えるための詰め物が間に入らない** — 宣言の
    /// 並びと Swift 側の詰め方が一致する理由はこれだけである。
    private static func packingOrder(
        of values: [String: ShaderValue]
    ) -> [(key: String, value: ShaderValue)] {
        values.sorted { ($0.value.byteSize, $0.key) > ($1.value.byteSize, $1.key) }
    }

    /// 値の名前ごとの、詰めた並びの中での先頭の**バイト位置** (``pack(_:)`` と同じ並び)。
    ///
    /// 宣言は組み立てるときに固定され、後から名前も形も変わらない (``ShaderBox/assign(_:_:willChange:)``)
    /// ので、持ち主は 1 度引いた表で、変えた値だけを詰め直せる (#2790)。位置を数でなくバイトで持つのは、
    /// `bool` が 1 バイトだからである。
    static func packedOffsets(of values: [String: ShaderValue]) -> [String: Int] {
        var offsets: [String: Int] = [:]
        offsets.reserveCapacity(values.count)
        var next = 0
        for (key, value) in packingOrder(of: values) {
            offsets[key] = next
            next += value.byteSize
        }
        return offsets
    }

    /// 値を、宣言した並びのとおりに詰める。
    ///
    /// 入れ物は `Float` の並びだが、中は Metal の構造体のバイト列そのもの (`int` は 32 ビットの整数、
    /// `bool` は 1 バイト)。長さは構造体の大きさを 16 バイト境界へ切り上げた分で、値の区画の数え方
    /// (``ShaderFailure/tooManyValues(path:count:capacity:)``) もこの長さで見る。
    static func pack(_ values: [String: ShaderValue]) -> [Float] {
        let sorted = packingOrder(of: values)
        guard !sorted.isEmpty else { return [0, 0, 0, 0] }
        // 構造体の大きさは 16 バイト境界へ切り上がる
        let bytes = sorted.reduce(0) { $0 + $1.value.byteSize }
        var packed = [Float](repeating: 0, count: (bytes + 15) / 16 * 4)
        packed.withUnsafeMutableBytes { buffer in
            var offset = 0
            for (_, value) in sorted {
                value.store(into: buffer, at: offset)
                offset += value.byteSize
            }
        }
        return packed
    }

    /// 面の宣言の行。1 枚も無ければ空。
    static func declarationLines(of surfaces: [String: ShaderSurface]) -> [DeclarationLine] {
        let names = surfaces.keys.sorted()
        guard !names.isEmpty else { return [] }
        let slots = (0..<ShapePipeline.surfaceCapacity)
            .map { "metal::texture2d<float> s\($0)" }.joined(separator: ", ")
        var lines: [DeclarationLine] = [
            ("#define MOKUME_SURFACES \(names.count)", nil), ("struct Surfaces {", nil),
        ]
        // **名前空間ごと書く。** この前置きは共通部分より前に出るので、`using namespace
        // metal;` がまだ効いていない (裸の `texture2d` は「そんな型は無い」で落ちる)
        lines += names.map { ("    metal::texture2d<float> \($0);", $0) }
        lines += [
            ("};", nil), ("static inline Surfaces mokume_surfaces(\(slots)) {", nil),
            ("    Surfaces surfaces;", nil),
        ]
        lines += names.enumerated().map { ("    surfaces.\($0.element) = s\($0.offset);", $0.element) }
        lines += [("    return surfaces;", nil), ("}", nil)]
        return lines
    }

    /// 面の名前と、断片からの受け取り方。
    ///
    /// 名前は断片の中で `surfaces.<名前>` として書ける。並べる順は名前順に固定する
    /// (値と同じ理由に加えて、**この順で口が割り当たる** — 辞書の順序に依らせると、
    /// 同じ断片が実行のたびに別の面を読む)。
    ///
    /// **1 枚も無ければ 1 バイトも出さない。** 面を宣言していない断片の原稿が動かない
    /// ことが、`#ifdef` で入口を切り替える形の前提である ([#407])。
    ///
    /// 口は使う枚数によらず ``ShapePipeline/surfaceCapacity`` 個ぶん受け取る — 入口の
    /// 側は断片ごとに口の数を変えられないので、余った口はここで捨てる。
    ///
    /// [#407]: https://github.com/mokume-metal/mokume/issues/407
    static func declaration(of surfaces: [String: ShaderSurface]) -> String {
        let lines = declarationLines(of: surfaces)
        guard !lines.isEmpty else { return "" }
        return lines.map(\.text).joined(separator: "\n") + "\n"
    }

    /// 本体が渡された名前から作った宣言の、行ごとの名前。組み立ての誤りが宣言を指したら、その名前を
    /// Swift の引数として名指す ([#2783] の反証)。
    ///
    /// 字の並びは通っても Metal で使えない名前がある — 予約語や組み込みの型 (`half` は
    /// `float half;` になる)、前置きのマクロ (`MOKUME_SURFACES`)。**表は持たない。** 予約語・型・
    /// マクロは Metal と前置きの版で増えるので、表はいずれ食い違う。代わりに組み立ての誤りを読む:
    ///
    /// - 誤り (error) が `mokume/Values:<行>` か `mokume/Surfaces:<行>` を指したら、その行に書いた名前
    /// - `note: expanded from macro '<名前>'` の名前が渡した名前なら、その名前 (前置きのマクロと同じ
    ///   名前の値を断片で読むと、誤りは書いた断片の行に出て、マクロの知らせが添う)
    ///
    /// 言い直しは理由の先頭に `<断片の名前>: error: the name "<名前>" in values: …` を名前ごとに
    /// 1 行ずつ足し、Metal の文面は下に残す。
    ///
    /// [#2783]: https://github.com/mokume-metal/mokume/issues/2783
    nonisolated struct DeclaredNames: Sendable {
        /// `mokume/Values` の行 (1 から) ごとの名前。
        let valueLines: [Int: String]
        /// `mokume/Surfaces` の行 (1 から) ごとの名前。
        let surfaceLines: [Int: String]
        let values: Set<String>
        let surfaces: Set<String>

        /// 理由を、名指しの行を先頭に足した形で返す。宣言の名前に当たらなければそのまま返す。
        func restating(_ reason: String, in fragment: String) -> String {
            var named: [(argument: String, name: String)] = []
            func note(_ argument: String, _ name: String?) {
                guard let name, !named.contains(where: { $0.argument == argument && $0.name == name })
                else { return }
                named.append((argument, name))
            }
            for line in reason.split(separator: "\n") {
                if let row = Self.row(of: line, in: "mokume/Values") {
                    note("values:", valueLines[row])
                } else if let row = Self.row(of: line, in: "mokume/Surfaces") {
                    note("surfaces:", surfaceLines[row])
                } else if let macro = Self.expandedMacro(in: line) {
                    if values.contains(macro) { note("values:", macro) }
                    if surfaces.contains(macro) { note("surfaces:", macro) }
                }
            }
            guard !named.isEmpty else { return reason }
            let lines = named.map { argument, name in
                "\(ShaderSource.oneLine(fragment)): error: the name \(name.debugDescription) in "
                    + "\(argument) cannot be used in Metal (a keyword, a type or a macro takes it), so "
                    + "rename it where you pass \(argument)"
            }
            return (lines + [reason]).joined(separator: "\n")
        }

        /// `<区切り>:<行>:<桁>: error:` の行の、行。誤り (error) の行だけを読む。
        private static func row(of line: Substring, in part: String) -> Int? {
            guard line.hasPrefix(part + ":"), line.contains(": error:") else { return nil }
            return Int(line.dropFirst(part.count + 1).prefix { $0.isNumber })
        }

        /// `note: expanded from macro '<名前>'` の名前。
        private static func expandedMacro(in line: Substring) -> String? {
            let marker = "note: expanded from macro '"
            guard let start = line.range(of: marker)?.upperBound,
                let end = line[start...].firstIndex(of: "'")
            else { return nil }
            return String(line[start..<end])
        }
    }

    /// ``DeclaredNames`` を、宣言と同じ行の並び (`declarationLines(of:)`) から作る。
    static func declaredNames(
        values: [String: ShaderValue], surfaces: [String: ShaderSurface] = [:]
    ) -> DeclaredNames {
        func rows(_ lines: [DeclarationLine]) -> [Int: String] {
            var rows: [Int: String] = [:]
            for (index, line) in lines.enumerated() { rows[index + 1] = line.name }
            return rows
        }
        return DeclaredNames(
            valueLines: rows(declarationLines(of: values)),
            surfaceLines: rows(declarationLines(of: surfaces)),
            values: Set(values.keys), surfaces: Set(surfaces.keys))
    }

    /// 原稿の 1 区切りと、その名前。組み立てた原稿の中で、区切りの頭の `#line` がこの名前と
    /// 1 行目を名乗る (``assemble(prelude:values:surfaces:body:)``)。
    struct Part: Equatable, Sendable {
        /// 組み立ての誤りが、区切りの中の行に添えて名乗る名前。
        var name: String
        var text: String
    }

    /// 本文が名乗る名前。ファイルから読んだ断片はファイル名 (`waves.metal`)、文字列から作った
    /// 断片は `name:` の名前。
    static func bodyName(_ name: String, url: URL?) -> String {
        url?.lastPathComponent ?? name
    }

    /// 原稿を組み立てる。
    ///
    /// ## 区切りごとに名乗る ([#2457])
    ///
    /// **区切り (値の宣言・面の宣言・前置きの各ファイル・本文) の頭に `#line 1 "<名前>"` を差す。**
    /// Metal の組み立ての誤りは、区切りの中で数え直した行と、その区切りの名前で出る — 本文の
    /// 誤りは `shader:2:12` (`name:` の名前か、ファイル名) の形で、書いた断片の行を指す。
    /// 差さなければ、前置きを足した原文の行 (`program_source:1053:12`) になり、書いた断片の
    /// どこにも無い行を指す。失敗の説明が言う「上の理由が指す所を、あなたが書いた断片の中で
    /// 直せ」が成り立たない。
    ///
    /// **前置きにも名乗りを差す。** 本文の名乗りだけだと、前置きの中の誤り (本体の不具合や、
    /// 前置きの定義を断片が定義し直したときの「前の定義」の知らせ) まで、前置きの頭から数えた
    /// 行で出る。前置きの名前は本体の名前 (`mokume/Common.metal`・`mokume/Values`) で、利用者の
    /// 名前を名乗らない。
    ///
    /// [#2457]: https://github.com/mokume-metal/mokume/issues/2457
    static func assemble(
        prelude: [Part], values: [String: ShaderValue],
        surfaces: [String: ShaderSurface] = [:], body: Part
    ) -> String {
        var parts = [Part(name: "mokume/Values", text: declaration(of: values))]
        // 面が無ければ、名乗りごと 1 バイトも出さない (面の宣言の約束・#407)
        let surfaceDeclaration = declaration(of: surfaces)
        if !surfaceDeclaration.isEmpty {
            parts.append(Part(name: "mokume/Surfaces", text: surfaceDeclaration))
        }
        parts += prelude
        parts.append(body)
        return parts.map { lineDirective(naming: $0.name) + $0.text + "\n" }.joined()
    }

    /// 次の行を、その名前の 1 行目として名乗る行。
    ///
    /// **名前は C の文字列なので、壊さない形に直す。** `name:` は利用者が何でも書ける。
    ///
    /// - `"` と `\` は逃がす。逃がさないと名前の途中で文字列が閉じ、原稿ごと組めなくなる
    /// - 改行と制御文字 (NUL を含む) は空白にする。改行は名乗りの行を割り、NUL は原稿をそこで
    ///   切る (Metal へ渡す C の文字列が NUL で終わる)
    /// - `?` は `\?` と書く。`??!`・`??/` などの三文字表記として読み替えられないように
    static func lineDirective(naming name: String) -> String {
        var escaped = ""
        for character in name {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "?": escaped += "\\?"
            case _ where breaksTheLine(character): escaped += " "
            default: escaped.append(character)
            }
        }
        return "#line 1 \"\(escaped)\"\n"
    }

    /// 改行と制御文字 (NUL を含む) か。1 行に収める文面で、空白に直す字。
    nonisolated static func breaksTheLine(_ character: Character) -> Bool {
        character.isNewline
            || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    /// 名前を、1 行を割らない形にする (改行と制御文字を空白に)。`name:` は利用者が何でも書けるので、
    /// 言い直しの 1 行 (`<断片の名前>: error: …`) に入れる前に通す。
    nonisolated static func oneLine(_ name: String) -> String {
        String(name.map { breaksTheLine($0) ? " " : $0 })
    }
}

/// 断片へ渡せる値。
///
/// `set(_:_:)` は Swift の値をそのまま受ける (``ShaderValueConvertible``)。この型を直に書くのは、
/// 作るときの `values:` の宣言か、`.int(n)` のように型を明示したいときだけである。
public enum ShaderValue: Equatable, Sendable {
    /// 1 つの数。断片からは `float` として見える。
    case number(Float)
    /// 2 つ組。断片からは `float2` として見える。
    case pair(Float, Float)
    /// 色。断片からは `float4` として見える (線形・アルファ乗算済み)。
    ///
    /// 断片の中で不透明度を変えるときは、`values.tint * 0.3` のように 4 成分に同じ数を掛ける。
    /// `float4(values.tint.rgb, 0.3)` は乗算済みの約束を崩す。
    case color(LinearRGBA)
    /// 3 つ組。断片からは `float3` として見える。向き・位置・軸ごとの倍率のように、3 つの数で 1 つの
    /// 意味を持つものに使う。
    ///
    /// Metal の `float3` は大きさが 16 バイトで、4 つめの場所は詰め物になる (宣言と詰め方は組み立てが
    /// 合わせるので、書く側は気にしなくてよい)。
    case vector3(Vector3)
    /// 真偽。断片からは `bool` として見える。
    case bool(Bool)
    /// 整数。断片からは `int` (32 ビット) として見える。
    ///
    /// **`Int` を渡すだけなら要らない** — `set("bands", n)` の `n` は `float` で届き、整数の
    /// リテラルも同じである (宣言を黙って変えない・[ADR-0035])。`int` で宣言されるのは、この case で
    /// 明示した値だけで、添字・`%`・ビット演算のように断片が整数で扱いたいときに使う。
    ///
    /// **宣言が `.int` なら、書き換えも `.int(n)` と書く。** `set("n", 5)` の `5` は `float` で届くので、
    /// `int` の宣言には「`float` を渡された」と断られる (宣言と違う型は受け付けない)。
    ///
    /// 32 ビットに収まらない値は、断らずに端 (`Int32.min`・`Int32.max`) に丸めて渡す。
    ///
    /// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
    case int(Int)
    /// 座標変換。断片からは `float4x4` として見える。
    ///
    /// 列を先に並べる Metal の行列で、`values.placement * float4(p, 1.0)` と書くと、``Transform`` を
    /// 掛けたときと同じ点に移る。
    case transform(Transform)

    var metalType: String {
        switch self {
        case .number: "float"
        case .pair: "float2"
        case .color: "float4"
        case .vector3: "float3"
        case .bool: "bool"
        case .int: "int"
        case .transform: "float4x4"
        }
    }

    /// 値の宣言に書く型の綴り。**行列だけ名前空間ごと書く** — 値の宣言は共通部分より前に出るので
    /// `using namespace metal;` がまだ効いておらず、裸の `float4x4` は「そんな型は無い」で落ちる
    /// (ベクトルの型は組み込みで、裸で書ける)。断片の中では、いつもどおり `float4x4` と書ける。
    var declaredType: String {
        if case .transform = self { return "metal::float4x4" }
        return metalType
    }

    /// Metal の構造体の中で占めるバイト数。**置く境界は、この大きさか 16 の小さいほう**
    /// (`float3` は 12 ではなく 16 バイトを占め、16 バイト境界に置かれる)。
    var byteSize: Int {
        switch self {
        case .number, .int: 4
        case .pair: 8
        case .color, .vector3: 16
        case .bool: 1
        case .transform: 64
        }
    }

    /// 値を、詰めた並び (``ShaderSource/pack(_:)``) の `offset` (バイト) から書き込む。**配列を作らない。**
    ///
    /// 書くのは値の成分だけで、詰め物 (`float3` の 4 つめなど) には触れない — 詰め物は最初から 0 で、
    /// 書き換えの間も 0 のままになる。
    func store(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        // 1 つの `Float` を、値の先頭から `byte` バイトの所へ書く
        func put(_ component: Float, _ byte: Int) {
            buffer.storeBytes(of: component, toByteOffset: offset + byte, as: Float.self)
        }
        switch self {
        case .number(let value):
            put(value, 0)
        case .pair(let x, let y):
            put(x, 0)
            put(y, 4)
        case .color(let color):
            put(color.red, 0)
            put(color.green, 4)
            put(color.blue, 8)
            put(color.alpha, 12)
        case .vector3(let vector):
            put(vector.x, 0)
            put(vector.y, 4)
            put(vector.z, 8)
        case .bool(let value):
            buffer.storeBytes(of: value ? 1 : 0, toByteOffset: offset, as: UInt8.self)
        case .int(let value):
            buffer.storeBytes(of: Int32(clamping: value), toByteOffset: offset, as: Int32.self)
        case .transform(let transform):
            let columns = transform.matrix.columns
            put(columns.0.x, 0)
            put(columns.0.y, 4)
            put(columns.0.z, 8)
            put(columns.0.w, 12)
            put(columns.1.x, 16)
            put(columns.1.y, 20)
            put(columns.1.z, 24)
            put(columns.1.w, 28)
            put(columns.2.x, 32)
            put(columns.2.y, 36)
            put(columns.2.z, 40)
            put(columns.2.w, 44)
            put(columns.3.x, 48)
            put(columns.3.y, 52)
            put(columns.3.z, 56)
            put(columns.3.w, 60)
        }
    }
}

extension ShaderValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(Float(value)) }
}

extension ShaderValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Float(value)) }
}
