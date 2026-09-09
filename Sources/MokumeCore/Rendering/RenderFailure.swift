// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画の土台で起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
///
/// **大半は「環境かリソースが足りない」形だが、それに限らない。** 頼んだ値が通らないもの
/// (``invalidSize(width:height:)`` / ``invalidPixelDensity(_:)``) と、呼ぶ順序が誤っているもの
/// (``commandsAlreadyOpen``) も同じ型で運ぶ。呼び出し側から見ればどれも `try` した先で
/// 起きたことで、運び方を分けても受け取る場所が増えるだけだからである ([#792])。
///
/// **区別を持つのは ``description`` のほうである。** 資源が足りないなら「走ったままの
/// スケッチを閉じてから試す」、呼び方が誤っているなら「呼ぶ場所を直す」と、次にすることが
/// 文面で分かれる — そこが揃っていないと、踏んだ人を間違った方向へ送る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [#792]: https://github.com/mokume-metal/mokume/issues/792
public enum RenderFailure: Error, Equatable, Sendable {
    /// GPU が見つからない (仮想環境・GPU を持たない実行環境)。
    case deviceUnavailable

    /// コマンドの発行口を作れない。
    case commandQueueUnavailable

    /// コマンドの置き場を作れない。
    case commandAllocatorUnavailable

    /// コマンドを 1 本作れない。
    case commandBufferUnavailable

    /// コマンドを組み立てている最中に、それを許さない口を呼んだ。**呼び出し順の誤り**で、
    /// 資源は足りている。
    ///
    /// 許さないのは、その口が自分のコマンドをもう 1 本開くからである。開いたまま置き場の
    /// 環を 1 周すると同じ置き場を二重に開くことになり、検証層が止める (層が無ければ
    /// 未定義)。いま該当するのは `RenderDevice.makeClearedTexture(descriptor:)` の 1 つ。
    case commandsAlreadyOpen

    /// 常駐させる集合を作れない。
    case residencySetUnavailable(reason: String)

    /// GPU の完了を待つための合図を作れない。
    case synchronizationUnavailable

    /// 指定した大きさの描画先を確保できない。
    case textureUnavailable(width: Int, height: Int)

    /// 読み出し先を確保できない。
    case bufferUnavailable(byteCount: Int)

    /// コマンドを書き込む口を作れない。
    case encoderUnavailable

    /// GPU の完了を待ったが、制限時間内に終わらなかった。
    ///
    /// 待ち時間の上限を秒で持つのは、検証が壁時計の絶対値ではなくこの値そのものを
    /// 物差しにできるようにするため。
    case timedOut(seconds: Int)

    /// 描画先の大きさが正しくない (幅・高さは 1 以上、面の一辺の上限以下でなければ
    /// ならない)。上限そのものは ``description`` が名乗る。
    ///
    /// **上限も同じ case で運ぶ。** 呼び出し側がすることは下限を割ったときと同じ
    /// (頼む大きさを直す) で、分けても選び分ける先が無い ([#885])。
    ///
    /// [#885]: https://github.com/mokume-metal/mokume/issues/885
    case invalidSize(width: Int, height: Int)

    /// 描く細かさが正しくない (0 より大きく 1 以下でなければならない)。
    ///
    /// 1 を超える指定 — 出すより細かく描いて縮める — は引き受けない。拡大器が
    /// 縮小を扱わないうえ、要求も出ていないためである。
    case invalidPixelDensity(Float)

    /// 同梱しているはずのシェーダの原文が見つからない。
    case shaderSourceMissing(name: String)

    /// シェーダを組み立てられない。
    case shaderCompilationFailed(name: String, reason: String)

    /// シェーダを組み立てる口を作れない。
    case shaderCompilerUnavailable

    /// 描画のパイプラインを作れない。
    case pipelineUnavailable(reason: String)

    /// 資源を渡すテーブルを作れない。
    case argumentTableUnavailable(reason: String)

    /// テクスチャの読み取り方を作れない。
    case samplerUnavailable
}

extension RenderFailure: CustomStringConvertible {
    /// 人が読む文面。
    ///
    /// **どの失敗にも「次に何をすればよいか」を書く。** 起動できなかったときに出る行は
    /// 利用者が最初に見る失敗で、しかも**配った先で出る** — 読む人は組み上げ方を知らない
    /// ことがあるので、状態の報告だけでは足りない ([#527])。道具の側 (`CommandFailure`) が
    /// 既に持っている規範を、ライブラリの側にも通す。
    ///
    /// **内部の名前をそのまま出さない。** case の綴りは実装の都合で決まっていて、読む人が
    /// 次にすることを決める助けにならない。準拠しているので `\(failure)` と書いた場所も
    /// この文面になる — 内部の名前が出る経路が残らない。
    ///
    /// **姉妹型と同じ形で公開する。** ``ImageFailure`` / ``ModelFailure`` / ``ShaderFailure``
    /// はいずれも `CustomStringConvertible` で人向けの文面を出しており、ここだけ internal
    /// だったせいで、アンブレラしか見えない場所 (参照スケッチ) が同じ文面を出せなかった
    /// ([#600])。実需ではなく**既にある規範が要求する一貫性の欠け**を埋めるもの
    /// ([ADR-0022] 決定 6 の 2 行目)。
    ///
    /// 走っている最中の警告は多行を流せないので、そちらは ``headline`` を使う。
    ///
    /// [#527]: https://github.com/mokume-metal/mokume/issues/527
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    /// [ADR-0022]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0022-production-track.md
    public var description: String {
        switch self {
        case .deviceUnavailable:
            """
            No GPU here.
            mokume runs only on a Mac that has one, and not inside a virtual machine.
            """
        case .commandQueueUnavailable:
            """
            Cannot create a command queue.
            \(Self.exhaustedAdvice)
            """
        case .commandAllocatorUnavailable:
            """
            Cannot create a command allocator.
            \(Self.exhaustedAdvice)
            """
        case .commandBufferUnavailable:
            """
            Cannot create a command buffer.
            \(Self.exhaustedAdvice)
            """
        case .commandsAlreadyOpen:
            // **資源枯渇の共通文面 (`Self.exhaustedAdvice`) へ寄せない。** あちらは「走った
            // ままのスケッチを閉じてから試す」で終わるが、ここで閉じても何も変わらない (#792)
            """
            Tried to make a painted surface while commands were still being assembled.
            This is the order of the calls rather than a shortage: make surfaces before the
            assembly begins, or after it has been submitted.
            """
        case .residencySetUnavailable(let reason):
            """
            Cannot create a residency set: \(reason)
            \(Self.exhaustedAdvice)
            """
        case .synchronizationUnavailable:
            """
            Cannot create the signal that waits for the GPU to finish.
            \(Self.exhaustedAdvice)
            """
        case .encoderUnavailable:
            """
            Cannot create a command encoder.
            \(Self.exhaustedAdvice)
            """
        case .textureUnavailable(let width, let height):
            """
            Cannot allocate a \(width)×\(height) render target.
            The GPU is out of memory — make the window smaller, or draw at a lower density.
            """
        case .bufferUnavailable(let byteCount):
            """
            Cannot allocate a \(byteCount)-byte buffer to read back into.
            The GPU is out of memory — handle fewer things at once.
            """
        case .timedOut(let seconds):
            """
            Waited \(seconds) seconds for the GPU and it never finished.
            One frame is drawing too much — draw fewer things, or make the shader lighter.
            """
        case .invalidSize(let width, let height):
            """
            That is not a valid size for a render target: \(width)×\(height)
            Width and height each have to be at least 1 and at most \(RenderDevice.maxTextureSide).
            """
        case .invalidPixelDensity(let density):
            """
            That is not a valid pixel density: \(density)
            It has to be above 0 and at most 1 (1 draws at exactly the density asked for, and
            anything smaller draws coarser and scales up).
            """
        case .shaderSourceMissing(let name):
            """
            Cannot find the source of a shader that ships with mokume: \(name)
            This is the failure that shows up most often after handing a work to someone: the
            resources did not make it into what was shipped. Check that
            \(ModuleResources.bundleName).bundle sits next to the executable (for a bundled
            work, in <name>.app/Contents/Resources/ or directly under <name>.app/). If it is
            not there, build the distribution again.
            """
        case .shaderCompilationFailed(let name, let reason):
            """
            Cannot build the shader: \(name)
            \(reason)
            Fix what the reason above points at, in the fragment you wrote.
            """
        case .shaderCompilerUnavailable:
            """
            Cannot make anything that compiles shaders.
            This machine's Metal falls short of what mokume asks for — check the macOS version.
            """
        case .pipelineUnavailable(let reason):
            """
            Cannot create the render pipeline: \(reason)
            Check that the shader's entry point name and the resources being passed line up.
            """
        case .argumentTableUnavailable(let reason):
            """
            Cannot create the table that passes resources: \(reason)
            Check whether too many resources are being passed at once.
            """
        case .samplerUnavailable:
            """
            Cannot create a way to read from a texture.
            \(Self.exhaustedAdvice)
            """
        }
    }

    /// 走っている最中に出す 1 行 (``description`` の先頭行 = 何が足りないか)。
    ///
    /// **`Diagnostics.warn` は 1 行しか流せない。** 宣言自身が「ライブラリからの注意を
    /// 1 行、標準エラーへ書く」と名乗っており、毎フレーム起こりうる失敗に多行を流すと
    /// 本当に読むべき行が埋まる (`SketchApplication.noteFrameFailure` のコメント)。
    ///
    /// **1 行に削るのは、人が端末で読む経路だけである** ([#600])。観測レポートの `warnings`
    /// は JSON の配列なので行数の制約が無く、読み手も機械なので全文 (`\(failure)`) を載せる
    /// — 組み立て直しの失敗はコンパイラの言葉が 2 行目に入るので、そこを削ると打つ手が
    /// 消える。起動の失敗も全文を出す (そこで終わりなので、次にすることまで要る)。
    ///
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    nonisolated var headline: String {
        String(description.prefix { $0 != "\n" })
    }

    /// GPU の資源が尽きているときに添える 1 行。
    ///
    /// **何が用意できなかったかは、各 case が完全な文で名乗る。** かつては骨組み 1 つに
    /// 名詞を流し込んで 8 通りを作っていたが、その形は語順の違う言語で組み替えられない
    /// (ADR-0038 決定 3)。共有するのは**独立した助言の 1 文**だけで、読む人が次にすること
    /// が同じであることは、その 1 文が同じであることで表す。
    private nonisolated static let exhaustedAdvice =
        "The GPU may have run out of resources — close any sketch still running and try again."
}
