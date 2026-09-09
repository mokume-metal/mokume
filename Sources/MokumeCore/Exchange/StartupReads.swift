// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 起動の瞬間にだけ読むもの。
///
/// ここに並ぶものは**プロセスが立ち上がる一瞬**に決まり、走っている間は動かない。後から
/// 変えても走っているプロセスは拾わないので、踏んだ人には「設定したのに効かない」としか
/// 見えず、実装を読むまで原因に辿り着けない ([#227](https://github.com/mokume-metal/mokume/issues/227))。
///
/// **一覧をここ 1 箇所に置く**のは、読む場所が増えるたびに案内へ文面を書き足す形をやめる
/// ためである ([#380](https://github.com/mokume-metal/mokume/issues/380))。読み手は自分の
/// 鍵をこの一覧から取り、応えないときの案内はこの一覧をそのまま出す。**一覧に載せずに読む
/// 経路は残さない** — 載っていない読み手が居ないことは検査が見る。
public enum StartupReads {
    /// 何から読むか。
    public enum Origin: String, Sendable {
        /// 環境変数。
        case environment
        /// 区画 (`.mokume/<名前>`) が在るかどうか。
        case facet
    }

    /// 誰が決めるか。
    ///
    /// **順序を間違えうるのは利用者が決めるものだけ**である。道具が決めるものは子プロセスへ
    /// 注入されるので、「起動した後に設定して効かない」という踏み方をしない — 代わりに
    /// **走らせる側と読む側で食い違う**という踏み方をする。
    public enum Decider: String, Sendable {
        /// 利用者。区画を自分で作る。
        case user
        /// 道具。子プロセスへ環境変数として渡す。
        case tool
    }

    /// 起動の瞬間に読むもの 1 件。
    public struct Entry: Sendable, Equatable {
        /// 案内に出す名前。
        public let name: String
        /// 何から読むか。
        public let origin: Origin
        /// 環境変数の名前、または区画の名前。
        public let key: String
        /// 誰が決めるか。
        public let decidedBy: Decider
        /// 何が決まるのか。案内はこれをそのまま出す。
        public let note: String
        /// この読みが実際に起きるファイル (リポジトリからの相対)。
        ///
        /// **読むのは検査だけ**なので公開しない。一覧から漏れた読み手を見つけるには、
        /// 一覧の側が「どこで読むか」まで名乗っている必要がある。
        let readSite: String

        /// この面の仕様の名前 (`Schemas/<これ>.schema.json`)。
        ///
        /// **既定は `<key>-report`。** 要求に応える面はみなその形をしている。一方通行の
        /// 面は応答を持たないので、自分の綴りを名乗る — 依存が持つ面を数える読み手
        /// (`DependencyFacets`) が、実在しない名前を探して「持たない」と誤って断定
        /// しないため ([#703](https://github.com/mokume-metal/mokume/issues/703))。
        public let schemaName: String

        init(
            name: String, origin: Origin, key: String, decidedBy: Decider, note: String,
            readSite: String, schemaName: String? = nil
        ) {
            self.name = name
            self.origin = origin
            self.key = key
            self.decidedBy = decidedBy
            self.note = note
            self.readSite = readSite
            self.schemaName = schemaName ?? "\(key)-report"
        }
    }

    /// やりとりのファイルを置く親。
    public static let workDirectory = Entry(
        name: "Facet base", origin: .environment, key: "MOKUME_WORK_DIR", decidedBy: .tool,
        note: "The parent that exchange files go under. If the runner and the reader "
            + "disagree on it, the two look at different facets",
        readSite: "Sources/MokumeCore/Exchange/WorkDirectory.swift")

    /// この実行を生んだ入力の世代。
    public static let sourceStamp = Entry(
        name: "Source stamp", origin: .environment, key: "MOKUME_SOURCE_STAMP", decidedBy: .tool,
        note: "Which generation of the source produced this run. Observation puts it "
            + "into its reply as is",
        readSite: "Sources/MokumeCore/Observation/SourceStamp.swift")

    /// 観測の区画。
    public static let observe = Entry(
        name: "Observation facet", origin: .facet, key: "observe", decidedBy: .user,
        note: "Present at launch turns observation on. Creating it while the sketch runs "
            + "has no effect",
        readSite: "Sources/MokumeCore/Observation/FrameObserver.swift")

    /// 入力の区画。
    public static let input = Entry(
        name: "Input facet", origin: .facet, key: "input", decidedBy: .user,
        note: "Present at launch lets input reach the sketch. Creating it while the sketch "
            + "runs has no effect",
        readSite: "Sources/MokumeCore/Input/InputInbox.swift")

    /// つまみの区画。
    public static let params = Entry(
        name: "Knob facet", origin: .facet, key: "params", decidedBy: .user,
        note: "Present at launch lets declared values be read and written from outside. "
            + "Creating it while the sketch runs has no effect",
        readSite: "Sources/MokumeCore/Parameters/ParamSurface.swift")

    /// 絵を渡す面の区画。
    ///
    /// **区画で道具が決めるのはこれだけである。** 他の区画は利用者が作るかどうかで
    /// 決まるが、これは見張り (`watch`) が子を起こす前に作る — 画面の出口をどこに
    /// 置くかは、起こした側にしか決められないからである ([ADR-0032] 決定 1)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    public static let viewport = Entry(
        name: "Viewport facet", origin: .facet, key: "viewport", decidedBy: .tool,
        note: "Present at launch hands baked frames to a shared surface instead of opening "
            + "a window. Creating it while the sketch runs has no effect",
        readSite: "Sources/MokumeCore/Display/SharedFrameSurface.swift",
        // 一方通行の面なので応答を持たない。仕様が名乗るのは置いた面の番号である
        schemaName: "viewport-surface")

    /// 走っている速さの名乗り。
    public static let frameRateNotice = Entry(
        name: "Frame rate notice", origin: .environment, key: "MOKUME_REPORT_RATE", decidedBy: .tool,
        note: "Says how fast it is running, once a second. The value is the configuration "
            + "name shown alongside, and the tool passes it only for run and watch",
        readSite: "Sources/MokumeCore/Display/FrameRateNotice.swift")

    /// 全部。**案内も検査もここを読む。**
    public static let all: [Entry] = [
        workDirectory, sourceStamp, frameRateNotice, observe, input, params, viewport,
    ]
}
