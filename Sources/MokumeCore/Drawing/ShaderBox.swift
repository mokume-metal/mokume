// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Synchronization

/// 利用者が書いた断片を持つものの骨。
///
/// ``Shader`` (塗り) ・``EffectShader`` (効果) ・``Computation`` (計算) が**内側に
/// 1 つずつ持つ**。3 つとも「宣言と照らして値を書き換える」「保存を拾って組み直す」を
/// 同じ順で書いていて、**直すときに 1 つ書き落とせる形**だった — [#787] が実際に
/// 開けた穴がそれである ([#892] で畳んだ)。
///
/// **組み立てそのものは持ち主に残る。** 何を組むか (塗りの平面と立体・効果の 1 本・
/// 計算の 1 本) も、組み上がったものをどう差し替えるかも 3 者で違い、ここに畳むと
/// 「平面と立体の両方が組み上がってから差し替える」のような約束が見えなくなる。
///
/// ## 裏で組む ([#2365])
///
/// 窓の経路 (``RenderDevice/rebuildsShadersInBackground``) では、保存を拾っても main で組まない。
/// 組み立ては裏で走らせ、その間は前の断片のまま描く。冷えた状態では、組み立てに 1 回 0.2 秒ほど
/// かかる。その場で組むと、保存のたびに窓がその間止まる。
///
/// - **組むのは 1 本まで。** 組んでいる間の保存は待たせ、組み上がった後にファイルの最新を組む。
///   Metal の組み立ては取り消せないので、すぐ並べると連打の数だけ積み上がる
/// - **差し替えも失敗の名乗りも、フレームの頭で行う** (``FileWatcher/takeChanges()``)。組んでいる間は
///   見張りの印を立て直し、毎フレームの頭で組み上がりを見に来る。組み上がりの知らせを main actor
///   の継続で受けると、main actor を譲らないループでは届かない ([#1830] と同じ穴)
/// - **組み上がったときにファイルが変わっていれば、その結果は捨てる。** 途中の保存の失敗は名乗らない
/// - 待つ経路 (書き出し・観測のフレーム) では、組んでいる仕事を捨ててその場で組む
///
/// [#787]: https://github.com/mokume-metal/mokume/issues/787
/// [#892]: https://github.com/mokume-metal/mokume/issues/892
/// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
/// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
final class ShaderBox {
    /// 断片の名前。
    let name: String
    /// 断片の在処。保存を拾い直すのに使う。持たなければ拾い直さない。
    let url: URL?
    /// 組み立ての誤りが、本文の行に添えて名乗る名前 (``ShaderSource/bodyName(_:url:)``)。
    var bodyName: String { ShaderSource.bodyName(name, url: url) }
    /// いま効いている値。
    private(set) var values: [String: ShaderValue]
    /// いまの値を、断片へ渡す並びに詰めたもの。**値が変わったときだけ書き換える** (#2790)。
    ///
    /// 読むたびに並べて詰め直すと、宣言が増えるほど、列を閉じるたびに払う費用が増える。列・頼みごとが
    /// 抱えるのはこの配列の写し (値型) で、書き換えるときに誰かが抱えていれば Swift の
    /// copy-on-write が分けるので、**積んだ後に値を変えても前の仕事は変わらない**。控えるのは 1 つだけで、
    /// 版ごとの控えは作らない。
    private(set) var packedValues: [Float]
    /// 名前ごとの、``packedValues`` の中の先頭の位置。宣言は組み立てるときに固定されるので 1 度引く。
    private let packedOffsets: [String: Int]
    /// いまのファイルの中身で差し替えられていなければ、その理由。**いま効いている中身と
    /// ファイルが揃えば下りる** (公開の説明は持ち主の `failure`)。
    private(set) var failure: String?
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    private(set) var generation = 0
    /// 最後に組み上がった断片の中身。**同じものを組み直さない**ための控え。
    private var compiledBody: String
    /// 最後に**組み立て (翻訳) に失敗した**中身。**同じものを組み直さず、同じ理由を言い直さない**
    /// ための控え。控えるのは中身のせいの失敗だけで、それ以外 (パイプラインを作れない・土台の
    /// 一時的な失敗) は控えず、次に保存を拾ったときに組み直す。
    private var failedBody: String?
    /// 診断: 失敗を知らせた回数 (読めなかった・組み立てに失敗した)。
    private(set) var failureReports = 0
    private(set) var watcher: FileWatcher?
    /// 裏で組んでいる 1 本 (型の説明の「裏で組む」)。
    private var inFlight: InFlight?
    /// 診断: 裏で組みに行った回数。
    private(set) var backgroundBuildsStarted = 0
    /// 診断: 裏で組んでいる仕事があるか。
    var isBuildingInBackground: Bool { inFlight != nil }
    /// 診断: 裏で組んでいる仕事が組み上がっているか (まだ採用していない)。
    var backgroundBuildFinished: Bool { inFlight?.outcome.isFinished ?? false }

    /// 警告の頭に付ける名乗り (`shader` / `effect` / `computation`)。
    private let label: String
    /// 宣言していない名前を渡されたときに案内する、値の書き場所。
    private let valuesHint: String

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        label: String, valuesHint: String
    ) {
        self.name = name
        self.url = url
        self.values = values
        self.packedValues = ShaderSource.pack(values)
        self.packedOffsets = ShaderSource.packedOffsets(of: values)
        self.compiledBody = body
        self.label = label
        self.valuesHint = valuesHint
    }

    /// 保存を拾い始める。
    ///
    /// **持ち主が組み上がってから呼ぶ。** 初期化の途中で拾い始めると、まだ組み上がって
    /// いない持ち主の `reload` が走る。
    func watch(_ onChange: @escaping () -> Void) {
        guard let url else { return }
        watcher = FileWatcher(url: url, onChange: onChange)
    }

    /// 宣言と照らして値を書き換える。受け付けたら `true`。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは
    /// 断片を読み込む (作る) ときに決める。
    ///
    /// - Parameter willChange: 値が**ビット列まで違う**と分かった後、書き換える直前に呼ぶ (#2789)。
    ///   断った入力と、同じ値の書き直しでは呼ばない。持ち主が、旧値を持つ列を閉じるために使う。
    @discardableResult
    func assign(_ name: String, _ value: ShaderValue, willChange: () -> Void = {}) -> Bool {
        guard let existing = values[name] else {
            Diagnostics.warn(
                "\(label): \"\(name)\" was never declared, so it cannot be passed. "
                    + "Write it in \(valuesHint) "
                    + "(what is there now: \(values.keys.sorted().joined(separator: ", ")))")
            return false
        }
        guard existing.componentCount == value.componentCount else {
            Diagnostics.warn(
                "\(label): \"\(name)\" has a different shape from its declaration "
                    + "(\(value.metalType) where \(existing.metalType) was declared)")
            return false
        }
        guard !existing.isBitwiseEqual(to: value) else { return true }
        willChange()
        values[name] = value
        // **詰めた写しも同じ所で書き換える。** 忘れると、列が閉じても次の列が古い値を拾う
        if let offset = packedOffsets[name] {
            packedValues.withUnsafeMutableBufferPointer { value.store(into: $0, at: offset) }
        }
        return true
    }

    /// 断片を読み直して、`rebuild` に組ませる。**その場で組む。**
    ///
    /// - Parameter rebuild: 読み直した中身から組み立てて差し替える。投げてよい。
    func reload(_ rebuild: @escaping (String) throws(RenderFailure) -> Void) {
        reload(
            inBackground: false,
            prepare: { (body: String) throws(RenderFailure) -> BuildJob<Void> in
                BuildJob(now: { () throws(RenderFailure) in try rebuild(body) })
            },
            adopt: { _ in })
    }

    /// 断片を読み直して、`prepare` が用意した仕事で組み、`adopt` で差し替えさせる。
    ///
    /// **失敗しても前のものを消さない。** 削ってから入れ直す形にすると、組み立てに
    /// 失敗した瞬間に元の断片ごと消えて絵が出なくなる。組めなければ `adopt` を呼ばず、
    /// 持ち主が抱えている組み上がりはそのまま残る。
    ///
    /// - Parameters:
    ///   - inBackground: 裏で組むか (型の説明の「裏で組む」)。`false` ならその場で組み、組んでいる
    ///     仕事は捨てる。
    ///   - prepare: 読み直した中身から、組む仕事を用意する (main で走る・安い)。投げてよい。
    ///   - adopt: 組み上がったものに差し替える。**呼ばれるのはフレームの頭か、その場で組んだとき。**
    func reload<Built: Sendable>(
        inBackground: Bool,
        prepare: (String) throws(RenderFailure) -> BuildJob<Built>,
        adopt: (Built) -> Void
    ) {
        guard let url else { return }
        let body: String
        do {
            body = try ShaderSource.body(at: url, path: url.path)
        } catch {
            // **読めなかった事情を名乗る** (#2358)。開けない (ディレクトリになった・読む権利が無い) のか、
            // UTF-8 でないのかで直す所が違う。消えたファイルも開けないので「見つかった」とは言わない
            let reason =
                switch error {
                case .unopenable(_, let location, let why): "Could not read the fragment \"\(location)\": \(why)"
                default: "Could not read the fragment: \(error.description)"
                }
            // 読めないままなら言い直さない (下の「失敗した中身も控える」と同じ理由)
            guard failure != reason else { return }
            failure = reason
            failedBody = nil
            report(reason)
            return
        }
        if let running = inFlight {
            if let outcome = running.outcome.take() {
                inFlight = nil
                // **組み上がったときにファイルが変わっていれば捨てる。** 途中の中身の失敗は名乗らず、
                // 下で最新の中身を組みに行く
                if running.body == body {
                    settle(body, outcome.map { $0 as! Built }, adopt: adopt)
                    return
                }
            } else if inBackground {
                // 組み上がるまで、毎フレームの頭で見に来る
                watcher?.keepPending()
                return
            } else {
                // 待つ経路: 組んでいる仕事を捨てて、その場で組む
                inFlight = nil
            }
        }
        // **同じ中身なら組み直さない。** 1 度の保存でファイル側と親ディレクトリ側の
        // 両方が反応するので、素直に組み直すと 1 度の保存で 2 度組み立てることになる。
        // 失敗した後で組み上がった中身へ戻したなら、効いている断片がファイルと揃ったので
        // 失敗の控えを下ろす
        guard body != compiledBody else {
            failure = nil
            failedBody = nil
            return
        }
        // **失敗した中身も控える** ([#1830] の反証 2)。親ディレクトリの書き込みも拾うので、断片と
        // 同じディレクトリへ連番を書き出すと、見張りはフレームごとに事象を拾う。組み上がった
        // 中身としか比べないと、組み立てに失敗する断片をフレームごとに組み直し、同じ警告を
        // フレームごとに出していた。直すのは作者が次に保存したときである
        //
        // [#1830]: https://github.com/mokume-metal/mokume/issues/1830
        guard body != failedBody else { return }
        let job: BuildJob<Built>
        do {
            job = try prepare(body)
        } catch {
            settle(body, .failure(error), adopt: adopt)
            return
        }
        if inBackground, let later = job.later {
            let outcome = BuildOutcome()
            inFlight = InFlight(body: body, outcome: outcome)
            backgroundBuildsStarted += 1
            // **main actor に触らずに組み、結果を器へ置くだけ。** 受け取るのはフレームの頭である
            Task.detached(priority: .userInitiated) {
                do throws(RenderFailure) {
                    outcome.store(.success(try await later()))
                } catch {
                    outcome.store(.failure(error))
                }
            }
            watcher?.keepPending()
            return
        }
        do {
            settle(body, .success(try job.now()), adopt: adopt)
        } catch {
            settle(body, .failure(error), adopt: adopt)
        }
    }

    /// 組み上がり (または失敗) を受け取る。
    private func settle<Built>(
        _ body: String, _ result: Result<Built, RenderFailure>, adopt: (Built) -> Void
    ) {
        switch result {
        case .success(let built):
            adopt(built)
            compiledBody = body
            failure = nil
            failedBody = nil
            generation += 1
        case .failure(let error):
            // **中身のせいと言える失敗だけを控える** (#1830 の 2 回目の反証 3)。組めなかった理由が
            // 中身と関係なければ、同じ中身でも次は組める。控えると、中身を変えるまで固着する
            if case .shaderCompilationFailed = error { failedBody = body } else { failedBody = nil }
            let reason = "\(error)"
            guard failure != reason else { return }
            failure = reason
            report(Self.rebuildWarning(for: error))
        }
    }

    /// 差し替えに失敗したときの、端末の警告の 1 行 (`could not rebuild the fragment: …`)。
    ///
    /// **組み立ての誤りなら、理由の中の最初の `error:` の行を ` — ` で足す** ([#2784])。1 行目の
    /// ``RenderFailure/headline`` は `Cannot build the shader: waves` で止まり、直す行 (`waves.metal:2:12`)
    /// は観測の ``failure`` にしか載らなかった。端末を見ながら保存を繰り返す場面で、観測を引かずに直す
    /// 行が分かる。足すのは**警告の側だけ**で、``RenderFailure/description`` と ``failure`` は変えない
    /// (変えると `makeShader` が投げる理由の中で同じ行が 2 度出る)。
    ///
    /// - 前に並ぶ警告の行 (`mokume/Common.metal:330:22: warning: …`) は飛ばし、最初の `error:` の行を
    ///   拾う。入口を書き違えた断片は、理由の先頭に足した言い直しの行 ([#2782]・`<断片の名前>: error: …`)
    ///   が最初の `error:` の行になり、Metal の `Undefined symbol(s)` ではなくそれが載る
    /// - 理由に `error:` の行が無い失敗 (組み立てでない失敗) は、今までどおり ``RenderFailure/headline``
    ///   だけ。警告は 1 行のまま ([#600])
    ///
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    /// [#2782]: https://github.com/mokume-metal/mokume/issues/2782
    /// [#2784]: https://github.com/mokume-metal/mokume/issues/2784
    static func rebuildWarning(for error: RenderFailure) -> String {
        let warning = "could not rebuild the fragment: \(error.headline)"
        guard case .shaderCompilationFailed(_, let reason) = error,
            let line = firstErrorLine(in: reason)
        else { return warning }
        return "\(warning) — \(line)"
    }

    /// 理由の中の最初の `error:` の行 (`waves.metal:2:12: error: …`)。無ければ `nil`。
    private static func firstErrorLine(in reason: String) -> String? {
        reason.split(whereSeparator: \.isNewline)
            .first { $0.contains(": error: ") || $0.contains(": fatal error: ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 失敗を 1 行知らせる。
    private func report(_ message: String) {
        failureReports += 1
        Diagnostics.warn("\(label): \(message)")
    }
}

/// 断片を組む仕事。**その場で組む口と、裏で組む口が同じ準備から組む** (``ShaderBox`` の「裏で組む」)。
struct BuildJob<Built: Sendable> {
    /// その場で組む。
    let now: () throws(RenderFailure) -> Built
    /// 裏で組む。main actor に触らない。`nil` なら裏では組めない (いつもその場で組む)。
    let later: (@Sendable () async throws(RenderFailure) -> Built)?

    init(
        now: @escaping () throws(RenderFailure) -> Built,
        later: (@Sendable () async throws(RenderFailure) -> Built)? = nil
    ) {
        self.now = now
        self.later = later
    }
}

extension ShaderBox {
    /// 裏で組んでいる 1 本。
    fileprivate struct InFlight {
        /// 組んでいる中身。
        let body: String
        let outcome: BuildOutcome
    }

    /// 裏の仕事が結果を置く器。**置くのは裏の糸、取るのはフレームの頭。**
    fileprivate nonisolated final class BuildOutcome: Sendable {
        private let slot = Mutex<Result<any Sendable, RenderFailure>?>(nil)

        func store(_ result: Result<any Sendable, RenderFailure>) {
            slot.withLock { $0 = result }
        }

        /// 置かれていれば取る。
        func take() -> Result<any Sendable, RenderFailure>? {
            slot.withLock { $0.take() }
        }

        var isFinished: Bool { slot.withLock { $0 != nil } }
    }
}
