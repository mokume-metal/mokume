// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画の土台で起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// どれも「環境かリソースが足りない」形の失敗で、呼び出し側の引数の誤りではない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public enum RenderFailure: Error, Equatable, Sendable {
    /// GPU が見つからない (仮想環境・GPU を持たない実行環境)。
    case deviceUnavailable

    /// コマンドの発行口を作れない。
    case commandQueueUnavailable

    /// コマンドの置き場を作れない。
    case commandAllocatorUnavailable

    /// コマンドを 1 本作れない。
    case commandBufferUnavailable

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

    /// 描画先の大きさが正しくない (幅・高さは 1 以上でなければならない)。
    case invalidSize(width: Int, height: Int)

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

    /// 表示できる面を用意できない。
    case displaySurfaceUnavailable
}
