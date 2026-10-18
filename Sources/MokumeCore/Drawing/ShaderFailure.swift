// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 断片を読み込めなかった理由。
public enum ShaderFailure: Error, Equatable, Sendable {
    /// 断片が見つからない。探した場所を添える。
    case notFound(path: String, searched: [String])
    /// 見つかったが、開けない。`location` は名前が解けた場所 (`..` を畳んだもの)、`reason` は
    /// OS が名乗った開けなかった事情 (ディレクトリだった・読む権利が無い、など)。中身の形式とは
    /// 関係が無いので、直すのは `location` にあるものの置き場か権利である
    /// (``DataFailure/unopenable(path:location:reason:)`` と同じ形・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    case unopenable(path: String, location: String, reason: String)
    /// 開けたが、中身を UTF-8 の文字として読めない (Shift_JIS で保存した断片など)。UTF-8 で保存し直す
    /// (``DataFailure/unreadable(path:)`` と同じ形・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    case unreadable(path: String)
    /// 断片を組み立てられない。理由はコンパイラの言葉のまま。
    ///
    /// **理由の行と桁は、書いた断片の中で数える** ([#2457](https://github.com/mokume-metal/mokume/issues/2457))。
    /// 桁は UTF-8 のバイトで数える (`波` は 3 桁ぶん)。文字列から作った断片は `name:` の名前
    /// (`shader:2:12`)、ファイルから読んだ断片はファイル名 (`waves.metal:2:12`) を名乗る。本体が前に
    /// 足す宣言を指す知らせ (断片が前置きの定義を定義し直したときの「前の定義」など) は、本体の名前
    /// (`mokume/Kinds.metal:29:15`) で出る。`mokume/Values`・`mokume/Surfaces` を名乗る誤りは、
    /// 渡した `values:`・`surfaces:` の名前から作った宣言の誤りで、Swift の側でその名前を直す。
    case notCompilable(path: String, reason: String)
    /// 渡す値が列 1 つぶんの区画に収まらない。float 換算の数と上限を添える。
    case tooManyValues(path: String, count: Int, capacity: Int)
    /// 渡す面が口の数に収まらない。枚数と上限を添える。
    case tooManySurfaces(path: String, count: Int, capacity: Int)
    /// 走っている面を取れない所で、この型を投げる資源の口を呼んだ。`call` は呼んだ口の名前
    /// (`"makeShader(_:name:values:surfaces:)"` など)。返すものを走っている面からしか作れないので、`setup()` などから呼び直す
    /// ([#2683](https://github.com/mokume-metal/mokume/issues/2683))。
    ///
    /// 面を取れるのは `setup()`・`draw()`・入力のコールバックの中 (待つ読み込みは、そこで起こした
    /// `Task` の中も) だけで、初期化子の中・後片付けの後・`Task` の中からは取れない。**名前に反して、
    /// スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした `Task` から
    /// 同期の口を呼んでもこの場合になる ([#1322](https://github.com/mokume-metal/mokume/issues/1322)
    /// と同じ事情)。
    case notRunning(call: String)
}

extension ShaderFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            return """
                Cannot find the fragment "\(path)".
                Looked in:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                If you did put it there, check that the package declares where its resources are \
                (`.executableTarget(..., resources: [.copy("assets")])`). \
                Without that declaration the build still passes quietly, and the file just cannot \
                be read at run time
                """
        case .unopenable(let path, let location, let reason):
            return AssetOpening.notice(path: path, location: location, reason: reason)
        case .unreadable(let path):
            return DataFailure.unreadable(path: path).description
        case .notCompilable(let path, let reason):
            return "Cannot build the fragment at \"\(path)\":\n\(reason)"
        case .tooManyValues(let path, let count, let capacity):
            return """
                Too many values for the fragment "\(path)" (\(count) counted as floats, but the \
                limit is \(capacity)).
                A color (float4) counts as 4 and a pair (float2) as 2 \
                (a struct's size rounds up to a multiple of 4, so the count can come out higher \
                than what you declared).
                The values ride in one fixed-size block per batch (per request, for compute), so \
                the limit cannot be raised. Pass fewer, or bundle what you can into a single color \
                or pair
                """
        case .tooManySurfaces(let path, let count, let capacity):
            return """
                Too many surfaces for the fragment "\(path)" (\(count), but the limit is \
                \(capacity)).
                Each named surface takes one slot, and the number of slots is fixed whatever the \
                fragment. Pass fewer, or combine several pictures into one (bake them side by \
                side, and pick one by where you read)
                """
        case .notRunning(let call):
            return OutsideRun.notRunningNotice(call)
        }
    }
}
