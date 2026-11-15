// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// シェーダを読み込めなかった理由。
public enum ShaderFailure: Error, Equatable, Sendable {
    /// シェーダが見つからない。探した場所を添える。
    case notFound(path: String, searched: [String])
    /// 見つかったが、開けない。`location` は名前が解けた場所 (`..` を正規化したもの)、`reason` は
    /// OS が返した開けなかった事情 (ディレクトリだった・読む権利が無い、など)。中身の形式とは
    /// 関係が無いので、直すのは `location` にあるものの保存場所か権利である
    /// (``DataFailure/unopenable(path:location:reason:)`` と同じ形・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    ///
    /// **親のフォルダに入れず、在るかを確かめられない場合も、この case で運ぶ** — `location` は確かめられ
    /// なかった場所で、`reason` は `cannot tell whether it exists (Permission denied)` の形になる。説明は
    /// 「見つかった」と言わず、リソースの宣言の助言も出さない ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。
    case unopenable(path: String, location: String, reason: String)
    /// 開けたが、中身を UTF-8 の文字として読めない (Shift_JIS で保存したシェーダなど)。UTF-8 で保存し直す
    /// (``DataFailure/unreadable(path:)`` と同じ形・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    case unreadable(path: String)
    /// シェーダをビルドできない。理由はコンパイラの言葉のまま。
    ///
    /// **理由の行と桁は、書いたシェーダの中で数える** ([#2457](https://github.com/mokume-metal/mokume/issues/2457))。
    /// 桁は UTF-8 のバイトで数える (`波` は 3 桁ぶん)。文字列から作ったシェーダは `name:` の名前
    /// (`shader:2:12`)、ファイルから読んだシェーダはファイル名 (`waves.metal:2:12`) で位置を示す。本体が前に
    /// 追加する宣言を指す通知 (シェーダが前置きの定義を定義し直したときの「前の定義」など) は、本体の名前
    /// (`mokume/Kinds.metal:29:15`) で出る。
    ///
    /// **エントリポイントを書き違えたシェーダは、期待するエントリポイントの形を先に言う** ([#2782](https://github.com/mokume-metal/mokume/issues/2782))。
    /// `paint`・`effect` の名前や引数が合わないとき、Metal の `Undefined symbol(s)` の前に
    /// `shader: error: the fragment does not define its entry point float4 paint(Fragment in, Values values)…`
    /// の 1 行が出る。計算は `name:` (ファイルならファイル名) の `kernel` 関数が無いことを言う。
    ///
    /// **`values:`・`surfaces:`・`numbers:` にシェーダの中で書けない名前を渡すと、ビルドの前にこの case で拒否する**
    /// ([#2783](https://github.com/mokume-metal/mokume/issues/2783))。理由は渡した引数と名前を名指しする。
    /// 受けるのは文字か `_` で始まり、文字・数字・`_` が続く名前 (ASCII の外の文字も受ける)。字の並びは
    /// 通っても Metal で使えない名前 (予約語・組み込みの型の `half`・前置きのマクロの `MOKUME_SURFACES`
    /// など) は、ビルドエラーの前に `shader: error: the name "half" in values: cannot be used in Metal…`
    /// の 1 行で名指しする。どちらも Swift の側でその名前を直す。
    case notCompilable(path: String, reason: String)
    /// 渡す値が列 1 つぶんの区画に収まらない。float 換算の数と上限を添える。
    case tooManyValues(path: String, count: Int, capacity: Int)
    /// 渡すサーフェスがスロットの数に収まらない。枚数と上限を添える。
    case tooManySurfaces(path: String, count: Int, capacity: Int)
    /// 名前で渡す数の並び (`numbers:`) がスロットの数に収まらない。本数と上限を添える
    /// ([#3576](https://github.com/mokume-metal/mokume/issues/3576))。
    case tooManyNumbers(path: String, count: Int, capacity: Int)
    /// 走っているキャンバスを取れない所で、この型を投げるリソースの API を呼んだ。`call` は呼んだ API の名前
    /// (`"createShader(_:name:values:surfaces:numbers:)"` など)。返すものを走っているキャンバスからしか作れないので、`setup()` などから呼び直す
    /// ([#2683](https://github.com/mokume-metal/mokume/issues/2683))。
    ///
    /// 実行中のスケッチを取得できるのは `setup()`・`draw()`・入力のコールバックの中 (待つ読み込みは、そこで生成した
    /// `Task` の中も) だけで、初期化子の中・後片付けの後・`Task` の中からは取れない。**名前に反して、
    /// スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで生成した `Task` から
    /// 同期の API を呼んでもこの場合になる ([#1322](https://github.com/mokume-metal/mokume/issues/1322)
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
                A float or an int counts as 1, a pair (float2) as 2, a color (float4) as 4, \
                a vector3 (float3, which takes 16 bytes) as 4, a transform (float4x4) as 16 and \
                a bool as a quarter (it takes 1 byte) \
                (a struct's size rounds up to a multiple of 4, so the count can come out higher \
                than what you declared).
                The values ride in one fixed-size block per batch (per pass for an effect, per request for compute), so \
                the limit cannot be raised. Pass fewer, or bundle what you can into a single \
                color, vector3 or pair
                """
        case .tooManySurfaces(let path, let count, let capacity):
            return """
                Too many surfaces for the fragment "\(path)" (\(count), but the limit is \
                \(capacity)).
                Each named surface takes one slot, and the number of slots is fixed whatever the \
                fragment. Pass fewer, or combine several pictures into one (bake them side by \
                side, and pick one by where you read)
                """
        case .tooManyNumbers(let path, let count, let capacity):
            return """
                Too many arrays in numbers: for the fragment "\(path)" (\(count), but the limit is \
                \(capacity)).
                Each named array takes one slot, and the number of slots is fixed whatever the \
                fragment. Pass fewer, or put several into one array (make it longer, and read each \
                part from its own offset)
                """
        case .notRunning(let call):
            return OutsideRun.notRunningNotice(call)
        }
    }
}
