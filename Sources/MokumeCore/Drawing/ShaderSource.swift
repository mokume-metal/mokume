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
    /// 探す場所は貼る絵と同じ並び (``ImageFile/candidates(for:)``)。名前は拡張子を
    /// 落としたファイル名で、計算ではこれが**断片の中の入口の関数の名前**にもなる。
    ///
    /// 3 者が同じ 7 行を持っていたので畳んだ — 候補の探し方が割れると、「読めない」が
    /// 断片の種類によって別の理由で出るようになる。
    ///
    /// [#895]: https://github.com/mokume-metal/mokume/issues/895
    static func read(at path: String) throws(ShaderFailure) -> (
        url: URL, body: String, name: String
    ) {
        let candidates = ImageFile.candidates(for: path)
        guard
            let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let body = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .notFound(path: path, searched: candidates.map(\.path))
        }
        return (url, body, url.deletingPathExtension().lastPathComponent)
    }

    /// 値の名前と、その形。
    ///
    /// 名前は**断片の中でそのまま書ける識別子**になる。並べる順は名前順に固定する
    /// (辞書の順序に依らせると、同じ断片が実行のたびに別の原稿になる)。
    static func declaration(of values: [String: ShaderValue]) -> String {
        // 4 成分のものを先に並べる。16 バイト境界に揃うものを先に置けば、
        // 詰め物の入り方が Swift 側の並べ方と一致する
        let sorted = values.sorted { ($0.value.componentCount, $0.key) > ($1.value.componentCount, $1.key) }
        let fields = sorted.map { "    \($0.value.metalType) \($0.key);" }
        // 空の構造体は大きさが処理系任せになるので、必ず 1 つは入れておく
        let body = fields.isEmpty ? "    float4 mokume_unused;" : fields.joined(separator: "\n")
        return "struct Values {\n\(body)\n};\n"
    }

    /// 値を、宣言した並びのとおりに詰める。
    static func pack(_ values: [String: ShaderValue]) -> [Float] {
        let sorted = values.sorted { ($0.value.componentCount, $0.key) > ($1.value.componentCount, $1.key) }
        guard !sorted.isEmpty else { return [0, 0, 0, 0] }
        var packed: [Float] = []
        for (_, value) in sorted { packed.append(contentsOf: value.components) }
        // 構造体の大きさは 16 バイト境界へ切り上がる
        while packed.count % 4 != 0 { packed.append(0) }
        return packed
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
        let names = surfaces.keys.sorted()
        guard !names.isEmpty else { return "" }
        // **名前空間ごと書く。** この前置きは共通部分より前に出るので、`using namespace
        // metal;` がまだ効いていない (裸の `texture2d` は「そんな型は無い」で落ちる)
        let fields = names.map { "    metal::texture2d<float> \($0);" }.joined(separator: "\n")
        let slots = (0..<ShapePipeline.surfaceCapacity)
            .map { "metal::texture2d<float> s\($0)" }.joined(separator: ", ")
        let assignments = names.enumerated()
            .map { "    surfaces.\($0.element) = s\($0.offset);" }.joined(separator: "\n")
        return """
            #define MOKUME_SURFACES \(names.count)
            struct Surfaces {
            \(fields)
            };
            static inline Surfaces mokume_surfaces(\(slots)) {
                Surfaces surfaces;
            \(assignments)
                return surfaces;
            }

            """
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
            case _ where character.isNewline
                || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }):
                escaped += " "
            default: escaped.append(character)
            }
        }
        return "#line 1 \"\(escaped)\"\n"
    }
}

/// 断片へ渡せる値。
public enum ShaderValue: Equatable, Sendable {
    /// 1 つの数。断片からは `float` として見える。
    case number(Float)
    /// 2 つ組。断片からは `float2` として見える。
    case pair(Float, Float)
    /// 色。断片からは `float4` として見える (線形・アルファ乗算済み)。
    case color(LinearRGBA)

    var metalType: String {
        switch self {
        case .number: "float"
        case .pair: "float2"
        case .color: "float4"
        }
    }

    var componentCount: Int {
        switch self {
        case .number: 1
        case .pair: 2
        case .color: 4
        }
    }

    var components: [Float] {
        switch self {
        case .number(let value): [value]
        case .pair(let x, let y): [x, y]
        case .color(let color): [color.red, color.green, color.blue, color.alpha]
        }
    }
}

extension ShaderValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(Float(value)) }
}

extension ShaderValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Float(value)) }
}
