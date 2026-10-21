// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 窓口が差し出す道具立て。
///
/// **面を増やすのではなく、既にある区画の往復を包むだけ。** ここに無い能力は
/// 区画を直に読み書きすれば同じように使えるし、逆にここが増えても面は増えない。
struct Tools {
    /// 公開 API の一覧を指す名前。面の仕様と同じ入口 (`reference`) に並べる。
    static let apiDocument = "api"
    /// 起動の瞬間に決まるものの一覧を指す名前。
    ///
    /// **道具を増やさず、既にある入口の責務を広げる** (ADR-0008 決定 5)。応えないときの
    /// 案内はここを名指すので、一覧へ辿り着く経路が窓口の中で閉じる (#380)。
    static let startupDocument = "startup"

    /// スケッチとやりとりする区画。基準は `MOKUME_WORK_DIR` が決める (#331)。
    let facets: Facets
    /// スケッチのパッケージの場所。**区画とは別の軸**で、SwiftPM に尋ねるときはこちらを
    /// 使う — `Package.swift` も `.build/` も、区画が動いてもここに留まる。
    let packageDirectory: URL
    /// 公開 API の一覧の在処。
    var apiList: APIListLocator
    /// 識別子の作り手。検査から固定できるようにする。
    var makeID: () -> String = { UUID().uuidString.prefix(8).lowercased() }

    /// 既定では 2 つの軸は重なる (区画の基準がパッケージの場所と同じ)。
    init(
        facets: Facets, packageDirectory: URL? = nil, apiList: APIListLocator? = nil,
        makeID: @escaping () -> String = { UUID().uuidString.prefix(8).lowercased() }
    ) {
        let package = packageDirectory ?? facets.directory
        // **窓口を立てた場所の事実は、組む時点で決める** (#2487)。立てる口 (`MCPCommand.run`) は
        // 自分で渡す。渡されなければパッケージの場所を見て埋める — 検査が組む窓口も、
        // 本物と同じく場所の事実を持つ
        var facets = facets
        if facets.place == nil { facets.place = .at(package) }
        self.facets = facets
        self.packageDirectory = package
        self.apiList = apiList ?? APIListLocator(directory: package)
        self.makeID = makeID
    }

    /// 差し出す道具。
    ///
    /// **綴りの正典はここ 1 つ。** かつては道具の名前が一覧の定義と ``call(_:arguments:)``
    /// の `switch` に別々の文字列リテラルで並んでいて、対応を保つ機械が居なかった
    /// ([#814](https://github.com/mokume-metal/mokume/issues/814))。いまは道具を足すと
    /// 定義と呼び出しの両方が**コンパイラに問われる**。
    enum ToolName: String, CaseIterable {
        case observe
        case buildStatus = "build_status"
        case input
        case reference

        /// 名前と説明と引数の形。一覧 (`tools/list`) はこれを並べたものである。
        var definition: [String: Any] {
            ["name": rawValue, "description": description, "inputSchema": inputSchema]
        }

        var description: String {
            switch self {
            case .observe:
                "Take a shot of the running sketch. Returns where the image is, along with a breakdown (frame number, time, size, a summary of the image, how hard it is working, the values the sketch exposed, and the source stamp). One shot of the current frame by default. Set count to 2 or more to take shots in succession without stopping the frames, and a catalogue in the order taken comes back — one frame cannot tell you whether motion is right, so use this for anything that moves. A stopped sketch still returns the last frame it drew. With time, redraw exactly one frame at those seconds (deltaTime=0). This changes the shown picture and retains draw side effects; it is not a rewind. noLoop stays stopped. External pause and recording refuse it. A null for an optional field (time / scale / count / every) reads the same as leaving it out; a name this tool does not list is refused, and so is a value of the wrong type."
            case .buildStatus:
                "Return the result of the most recent build (whether it passed, whether the sketch was started, the exit code, the output, a breakdown of how long it took, and the source stamp). A build that passed but did not start the sketch (ok true, launched false) leaves the drawing frozen; notStartedReason says why. Read this when you want to know why the drawing did not change."
            case .input:
                "Send input events to the running sketch. Coordinates are in the canvas coordinate system. The types are mouseDown / mouseUp / mouseMoved / mouseMovedBy / scrolled / keyDown / keyUp. The three positional types need x and y; the two key types need code (the macOS virtual key code: 49 = Space, 0 = A, 126 = up arrow). An event missing one is counted in ignored and the rest still go through. mouseMovedBy moves by dx and dy (canvas pixels, down is positive) without changing mouseX / mouseY, as a sketch that holds the pointer (requestPointerLock()) receives it; it reaches mouseMoved(deltaX:deltaY:), or mouseDragged(deltaX:deltaY:) while a button is held. button / dx / dy / characters / isRepeat can be left out. keyPressed() fires only when a key that is not held goes down, so a repeat (isRepeat true) reaches keyTyped() alone. The modifier keys (56 / 60 = Shift, 59 / 62 = Control, 58 / 61 = Option, 55 / 54 = Command) only change which keys are held, which the sketch reads with keyboard.isPressed(.shift). button is the macOS button number (0 = left, the primary one, and the default; 1 = right; 2 = center), which is not the browser order, where 1 is the middle button and 2 the secondary one."
            case .reference:
                "Return a document this interface serves. With no argument you get the list; pass name for one of them. Pass api for the public API of the version currently depended on (which types and functions exist, and how to call them). Pass startup for the things decided the moment a process starts (the ones that have no effect while it runs). The rest are surface specs (the shape of requests and replies)."
            }
        }

        /// 引数の形。**余りの名前は断る** (`additionalProperties: false`・#2486)。
        var inputSchema: [String: Any] {
            var schema = properties
            schema["additionalProperties"] = false
            return schema
        }

        /// 受ける名前 (`inputSchema` の `properties` のキー)。**受ける名前の正典はここ 1 つ**で、
        /// `Tools.call` が余りを断るときも、この一覧を見る。
        var acceptedArguments: [String] {
            ((properties["properties"] as? [String: Any]) ?? [:]).keys.sorted()
        }

        private var properties: [String: Any] {
            switch self {
            case .observe:
                [
                    "type": "object",
                    "properties": [
                        "time": [
                            "type": "number", "minimum": 0,
                            "maximum": Double(Float.greatestFiniteMagnitude),
                            "description": "Draw and capture one frame at these seconds, rounded to Float. Requires count=1 and every=1. Only draw() reads this time; input callbacks, a playing video and a recorded sound follow the author's clock. Update the sketch dependency if its reply lacks appliedTime.",
                        ],
                        "scale": [
                            "type": "number",
                            "exclusiveMinimum": 0,
                            "maximum": 1,
                            "description": "How far to scale the written image down (above 0, up to 1). Omit for full size.",
                        ],
                        "count": [
                            "type": "integer",
                            "minimum": ObservationRequest.minimumCount,
                            "maximum": ObservationRequest.maximumCount,
                            "description":
                                "How many shots to take (\(ObservationRequest.minimumCount)…\(ObservationRequest.maximumCount)). Omit for one.",
                        ],
                        "every": [
                            "type": "integer",
                            "minimum": ObservationRequest.minimumEvery,
                            "maximum": ObservationRequest.maximumEvery,
                            "description":
                                """
                                Take a shot every N frames (\(ObservationRequest.minimumEvery)…\(ObservationRequest.maximumEvery)). \
                                Omit to take every frame. Counted in frames rather than seconds, \
                                and the sketch being observed runs on the wall clock unless it chose \
                                `clock: .frames`, so the shots are not evenly spaced in time — lay the series out by each entry's \
                                `time` in the reply's catalogue, rather than assuming an even gap. \
                                For motion with evenly spaced times, write it with `mokume render` \
                                instead (a fixed frame rate, every frame written).
                                """,
                        ],
                    ],
                ]
            case .buildStatus:
                ["type": "object", "properties": [:]]
            case .input:
                [
                    "type": "object",
                    "required": ["events"],
                    "properties": [
                        "events": [
                            "type": "array",
                            "description": "The events to send. Any number of them in one call.",
                            "items": ["type": "object"],
                        ]
                    ],
                ]
            case .reference:
                [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The document's name (for example api, startup, observe-report).",
                        ]
                    ],
                ]
            }
        }
    }

    /// 一覧。名前と説明と引数の形。
    static let definitions: [[String: Any]] = ToolName.allCases.map(\.definition)

    /// 道具を呼ぶ。
    func call(_ name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        guard let tool = ToolName(rawValue: name) else {
            return ("There is no such tool: \(name)", true)
        }
        // **余りの名前は、値によらず (`null` でも) 道具を走らせずに断る** (#2486)。黙って捨てると、
        // `scal` の綴り違いが既定で撮る頼みに化け、撮る側の警告にも載らない。範囲は `arguments` の
        // 直下だけで、`input` の各出来事の中の欄は区画の読み手が扱う
        let unknown = arguments.keys.filter { !tool.acceptedArguments.contains($0) }.sorted()
        if !unknown.isEmpty { return (Self.unknownArgumentsText(unknown, tool: tool), true) }
        switch tool {
        case .observe: return observe(arguments)
        case .buildStatus: return buildStatus()
        case .input: return sendInput(arguments)
        case .reference: return reference(arguments)
        }
    }

    /// 余りの引数を断る文。知らない名前と、受ける名前を言う。
    static func unknownArgumentsText(_ unknown: [String], tool: ToolName) -> String {
        let accepted = tool.acceptedArguments
        let names = unknown.joined(separator: ", ")
        let lead = unknown.count == 1 ? "Unknown argument: \(names)." : "Unknown arguments: \(names)."
        return accepted.isEmpty
            ? "\(lead) \(tool.rawValue) takes no arguments."
            : "\(lead) \(tool.rawValue) accepts \(accepted.joined(separator: ", "))."
    }

    /// 値が `null` の欄を「渡していない」ことにする (#2393)。
    ///
    /// **省略可能な欄の `null` は、型の誤りではなく省略と同じに読む。** LLM は省略できる欄に
    /// `null` を入れることがあり、断ると呼び出しが失敗する。型の違う値 (`"3"`・`true`) は断る
    /// ままである (#2408)。必須の欄 (`events`) の `null` は省略ではないので、`input` では使わず、
    /// 従来どおり `events needs an array of events` と断る。
    static func droppingNulls(_ arguments: [String: Any]) -> [String: Any] {
        arguments.filter { !($0.value is NSNull) }
    }

    private func observe(_ given: [String: Any]) -> (String, Bool) {
        let arguments = Self.droppingNulls(given)
        let id = makeID()
        var request: [String: Any] = ["id": id]
        // **数でない縮尺は断る。** 黙って落とすと等倍の頼みに化け、撮る側の警告にも載らない。
        // 真偽値は `NSNumber` 経由で 1 に読めてしまうので、型で見分ける (`time` と揃える・#2319)。
        // 有限でない数も断る — 通すと区画を作った後で書けずに、置き場所のせいにした案内が
        // 返る。窓口の入口 (`JSONRPC.parse`) が、木に残った `-1e400` (`-inf` と読まれる) を行ごと
        // 断るので、ここへは通常来ない。**多層防御として残す** — 入口が見るのは読んだ木で、
        // 同じキーを 2 度書いた行の後ろの値のように木から落ちた数は見ないが、落ちた数は
        // ここへも届かない。`Tools` を直に呼ぶ口 (検査・将来の呼び元) のためにも判定は持つ。
        // 範囲では切らない — 範囲の外は撮る側が
        // 等倍で書いて警告で名乗る (observe-request の約束)。`null` は入口で落としてあり、
        // 省略と同じに読む (#2393)
        if let raw = arguments["scale"] {
            guard let scale = JSONRPC.number(raw), scale.doubleValue.isFinite else {
                return ("scale must be a finite number", true)
            }
            request["scale"] = scale.doubleValue
        }
        var requestedTime: Double?
        if let raw = arguments["time"] {
            guard let value = JSONRPC.number(raw),
                value.doubleValue.isFinite, value.doubleValue >= 0,
                value.doubleValue <= Double(Float.greatestFiniteMagnitude) else {
                return ("time must be finite, non-negative seconds within the Float range", true)
            }
            for key in ["count", "every"] {
                if let raw = arguments[key] {
                    guard let value = JSONRPC.number(raw), value.doubleValue == 1 else {
                        return ("A specified time requires count=1 and every=1", true)
                    }
                }
            }
            requestedTime = value.doubleValue
            request["time"] = value.doubleValue
        }
        // **範囲では切らずに、そのまま渡す。** 範囲の外の頼みは撮る側が端へ丸め、切ったことを
        // 応答の警告で名乗る (observe-request の約束)。ここで切ると、その警告が出ない (#2045)
        var series: [String: Int] = [:]
        for key in ["count", "every"] {
            switch Self.seriesArgument(arguments[key], key: key) {
            case .omitted: break
            case .value(let value): series[key] = value
            case .refused(let text): return (text, true)
            }
        }
        let count = series["count"]
        let every = series["every"]
        if let count { request["count"] = count }
        if let every { request["every"] = every }
        let report: [String: Any]
        switch roundTrip(
            facet: facets.observeFacet, entry: StartupReads.observe, request: request, id: id,
            extraWait: Self.extraWait(count: count, every: every))
        {
        case .refused(let text): return (text, true)
        case .answered(let answer): report = answer
        }

        if let requestedTime, let failure = Self.timeObservationFailure(report, requested: requestedTime) {
            return (failure + "\n\n" + pretty(report), true)
        }
        var lines: [String] = []
        let frames = (report["frames"] as? [[String: Any]]) ?? []
        var names = frames.compactMap { $0["image"] as? String }
        // **目録が無ければ単数形へ落ちる。** 目録 (#408) を書かない版のライブラリと繋がる
        // ことは避けられない — 作品は再現のために版を固定してコミットし、道具は独立に
        // 新しくなる。落ちなければ、絵が在るのに「採れませんでした」と答えることになる
        // (#635)。**判定は形から行う** — 目録を足したとき schemaVersion は据え置かれたので、
        // 版を名乗る値では新旧を分けられない (ADR-0018 決定 5 の追補)
        let manifestMissing = names.isEmpty
        if manifestMissing, let single = report["image"] as? String { names = [single] }

        if names.isEmpty {
            lines.append("No image could be taken")
        } else if names.count == 1 {
            lines.append("Image: \(facets.observeFacet.appendingPathComponent(names[0]).path)")
        } else {
            // 何枚あるかを先に言う。頼んだ枚数と食い違っていたら、そこで気付ける
            lines.append(
                """
                Images (\(names.count)): \(facets.observeFacet.path)/
                  \(names.joined(separator: " "))
                """)
        }
        // **黙って寛容にはしない。** 目録は面の仕様が要求しているもの (ADR-0018 決定 4) で、
        // 無いまま読めたのは読み手が補ったからである。補ったことは読み手が名乗る
        if manifestMissing, !names.isEmpty {
            lines.append(Self.manifestMissingNote(count: count ?? 1))
        }
        lines.append(pretty(report))
        return (lines.joined(separator: "\n\n"), false)
    }

    /// 版だけで成功とは判断しない。旧版は未知の要求を無視するため、適用の印と絵の時刻を照合する。
    static func timeObservationFailure(_ report: [String: Any], requested: Double) -> String? {
        guard let applied = report["appliedTime"] as? Double else {
            let warnings = (report["warnings"] as? [String]) ?? []
            if report["image"] == nil, !warnings.isEmpty { return warnings.joined(separator: "\n") }
            return "The reply does not confirm the requested time (appliedTime is missing). "
                + "The sketch may use an older mokume. Update the sketch's own dependency; this image is not a time-specific result."
        }
        let expected = Double(Float(requested))
        guard applied == expected,
            JSONRPC.number(report["appliedTime"]) != nil,
            let topTime = JSONRPC.number(report["time"]), topTime.doubleValue == expected,
            let frames = report["frames"] as? [[String: Any]], frames.count == 1,
            let frameTime = JSONRPC.number(frames[0]["time"]), frameTime.doubleValue == expected,
            let image = report["image"] as? String, !image.isEmpty,
            frames[0]["image"] as? String == image else {
            return "The reply does not match the requested time or single image. No time-specific result was accepted."
        }
        return nil
    }

    /// 目録を書かない書き手と繋がったときに添える。
    ///
    /// **頼んだ枚数が返らないときは、そちらを先に言う。** 絵が 1 枚返っている以上、読み手は
    /// 成功と受け取る — 続けて撮ることは目録を書く版でしか成立しないので、黙っていると
    /// 「動きを見た」と誤って判断される (#635)。
    static func manifestMissingNote(count: Int) -> String {
        let cause = """
            This reply has no catalogue (frames). The mokume the sketch depends on predates
            the version that added one. The image name was read from the singular image field.
            """
        guard count > 1 else { return cause }
        return """
            \(count) shots were asked for and only one came back. \(cause)
            To take a series, update the sketch's own dependency.
            """
    }

    /// 列を撮り終えるまでにかかるぶん、待ちに足す時間。
    ///
    /// 撮り終えるまでにフレームが `(count - 1) * every + 1` 枚ぶん進む。**足さないと、
    /// 応答は後から正しく書かれるのに読み手だけが諦めた状態**になり、次の要求が
    /// その古い目録を掴む。
    ///
    /// フレームレートは分からないので、遅い側 (30fps) を見込んで換算する。
    ///
    /// **撮る側が丸めた値で見積もる** (#2045)。範囲の外の頼みは撮る側が端へ丸めて撮るので、
    /// 丸め方は撮る側の `ObservationRequest.clamped()` をそのまま使い、範囲を写さない。
    /// 丸めずに掛けると、スキーマの外の値 (`every = Int.max` など) で Int が溢れ、
    /// 窓口のプロセスごと落ちる。
    static func extraWait(count: Int?, every: Int?) -> TimeInterval {
        let limits = ObservationRequest(id: "", count: count ?? 1, every: every ?? 1).clamped()
        return Double((limits.count - 1) * limits.every + 1) / 30
    }

    /// 枚数・間隔の引数の読み方。
    enum SeriesArgument: Equatable {
        /// 渡されていない。撮る側の既定 (1) に任せる
        case omitted
        /// 整数として読めた値。範囲の外でも切らない
        case value(Int)
        /// 整数として読めない。理由の文
        case refused(String)
    }

    /// 枚数・間隔の引数を、範囲では切らずに整数として読む (#2045)。
    ///
    /// **整数でない値は断る。** 黙って既定の 1 へ倒すと、`every = 2.5` や `count = "3"` が
    /// 毎フレーム 1 枚の頼みに化け、撮る側の警告にも載らない。`time` が型の違いを断るのと
    /// 揃える。
    ///
    /// **Int に収まらない整数は、符号の側の端へ寄せる。** `1e19` も `Int.max` も「上限より
    /// 大きい」ことに変わりはなく、撮る側が上限へ丸めて警告で名乗る。
    static func seriesArgument(_ raw: Any?, key: String) -> SeriesArgument {
        guard let raw else { return .omitted }
        let refusal = SeriesArgument.refused("\(key) must be a whole number")
        guard let number = JSONRPC.number(raw) else { return refusal }
        if let exact = raw as? Int { return .value(exact) }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded() else { return refusal }
        return .value(double > 0 ? Int.max : Int.min)
    }

    private func buildStatus() -> (String, Bool) {
        guard let status = facets.read(facets.buildStatus) else {
            let missing = """
                No build has been recorded yet. Either `\(Command.name) watch` is not running,
                or it has not built anything so far.
                """
            // **記録を書くのは `watch` で、書く先は `watch` の区画の基準** (スケッチの場所)。
            // 窓口の区画の基準がスケッチでない場所に落ちていれば、走っている `watch` の記録は
            // ここからは読めない (#2487)。その場所から組み上げた実行ファイルを起こす使い方では
            // 作り直しがそもそも無いので、そう言い分ける — 一手を勧めるのは前者に対してだけである
            guard facets.facetsOutsideSketch, let place = facets.place else { return (missing, true) }
            return (
                """
                \(missing)

                \(place.note)

                `\(Command.name) watch` records its builds under the sketch's own directory, so an interface
                started elsewhere does not see them. A built app started from \(place.directory.path)
                itself is never rebuilt, so for that one there is no record to read.
                """, true
            )
        }
        return (pretty(status), false)
    }

    private func sendInput(_ arguments: [String: Any]) -> (String, Bool) {
        guard let events = arguments["events"] as? [[String: Any]] else {
            return ("events needs an array of events", true)
        }
        let id = makeID()
        switch roundTrip(
            facet: facets.inputFacet, entry: StartupReads.input,
            request: ["id": id, "events": events], id: id)
        {
        case .refused(let text): return (text, true)
        case .answered(let report): return (pretty(report), false)
        }
    }

    /// 区画へ 1 往復した結果。
    private enum Exchange {
        /// 応答が返った。
        case answered([String: Any])
        /// 返らなかった。**何が起きたのかと、次に何をすればよいか**を持つ。
        case refused(String)
    }

    /// 区画へ要求を置き、応答が返るまで待つ。
    ///
    /// **観測と入力で骨格を 2 度書かない。** 置く → 待つ → 返らなければ「なぜ返らないか」を
    /// 名乗る、という並びは同じで、違うのは区画と要求の中身だけである。2 度書いていたころ、
    /// 片方だけが `existed` を控え忘れる形の間違いが成立していた。
    ///
    /// **区画の有無は要求を置く前に控える。** ``Facets/exchange(facet:request:id:...)`` は
    /// 待つ前に自分で区画を作るので、後から見ても「元から在ったのか」が分からなくなる
    /// ([#227](https://github.com/mokume-metal/mokume/issues/227)) — その区別で案内が
    /// 変わるので、控える場所を間違えると読み手を直らない道へ送る。
    private func roundTrip(
        facet: URL, entry: StartupReads.Entry, request: [String: Any], id: String,
        extraWait: TimeInterval = 0
    ) -> Exchange {
        let existed = facets.hasFacet(facet)
        // 撮り直してよいのは、副作用を残さない観測だけ。`time` 付きは 1 フレームを描き直す (#2857)
        let repeatable = entry == StartupReads.observe && request["time"] == nil
        do {
            switch try facets.exchange(facet: facet, request: request, id: id, extraWait: extraWait) {
            case .answered(let report):
                return .answered(report)
            case .contested:
                return .refused(facets.contested(entry, repeatable: repeatable))
            case .timedOut(let replaced):
                // 期限の時点で別の書き手が要求を置き換えていたら、走っていないとは言わず、取り合いとして答える
                return .refused(
                    replaced
                        ? facets.replacedAtDeadline(entry, repeatable: repeatable)
                        : facets.notRunning(entry, existed: existed))
            }
        } catch {
            // **置けなかった回も、場所の手を添える** (#2487)。窓口は在る場所なら受けるので、
            // `/` や読み取り専用の場所でも立つ。区画の基準がそこに落ちていれば、書き込めるか・
            // 容量・`MOKUME_WORK_DIR` だけを言うと、場所を渡す手が抜ける
            guard facets.facetsOutsideSketch, let place = facets.place else {
                return .refused(error.message)
            }
            return .refused("\(error.message)\n\n\(place.note)")
        }
    }

    private func reference(_ given: [String: Any]) -> (String, Bool) {
        let arguments = Self.droppingNulls(given)
        let name = arguments["name"] as? String
        // **文字列でない名前は断る。** 「引数なし」に倒すと、頼んだ文書の代わりに一覧が成功として
        // 返り、頼み方を誤ったことに気付けない (#2319)。`null` は入口で落としてあり、省略と同じに読む (#2393)
        if arguments["name"] != nil, name == nil {
            return ("name must be a string (a document's name). Omit it to get the list.", true)
        }
        // 公開 API は面の仕様と出所が違う (版ごとの資産) が、**入口は 1 つに保つ**
        if name == Self.apiDocument { return apiReference() }
        if name == Self.startupDocument { return (startupReference(), false) }

        let root = SchemasLocator.directory(workDirectory: packageDirectory)
        guard let name else { return (catalog(schemas: root), false) }
        guard let root else { return (schemasMissing(), true) }
        guard let text = SchemasLocator.contents(of: name, in: root) else {
            return ("There is no document by that name: \(name)", true)
        }
        return (text, false)
    }

    /// 配っているものの一覧。
    func catalog(schemas root: URL?) -> String {
        var lines = [
            "Documents this interface serves (pass one as name to get its contents):",
            "",
            "Public API:",
            "- \(Self.apiDocument) — the public API of the version currently depended on",
            "",
            "Decided at launch:",
            "- \(Self.startupDocument) — what has no effect while a process is running",
            "",
            "Surface specs:",
        ]
        if let root {
            lines += SchemasLocator.names(in: root).map { "- \($0)" }
        } else {
            lines.append(schemasMissing())
        }
        return lines.joined(separator: "\n")
    }

    /// 公開 API の一覧。**どこから得たかを添える。**
    private func apiReference() -> (String, Bool) {
        do {
            let found = try apiList.read()
            return ("Source: \(found.source.text)\n\n\(found.text)", false)
        } catch let missing as APIListLocator.Missing {
            // **版が引けない回だけ、場所の手を添える** (#2487)。スケッチでない場所には
            // `Package.resolved` も無いので、理由を「パスで指しているとき」とだけ言うと取り違える。
            // 版を読むのはパッケージの場所なので、区画の基準 (`MOKUME_WORK_DIR`) には依らない。
            // 取りに行けない・読めない回は場所のせいではないので添えない
            guard missing.cause == .versionUnknown, let place = facets.place, !place.isSketch
            else { return (missing.advice, true) }
            return ("\(missing.advice)\n\n\(place.note)", true)
        } catch {
            return ("Could not read the public API list: \(error)", true)
        }
    }

    /// 起動の瞬間に決まるものの一覧。
    func startupReference() -> String {
        StartupReadsReport.document(
            base: facets.directory, given: facets.workDirectoryGiven,
            package: packageDirectory)
    }

    /// 面の仕様が見つからないときの答え。**どこを見たかまで書く。**
    func schemasMissing() -> String {
        let searched = SchemasLocator.candidates(workDirectory: packageDirectory)
            .map { "- \($0.path)" }.joined(separator: "\n")
        return """
            Cannot find the surface specs. Looked in:

            \(searched)

            If you depend on mokume as a package, run `swift build` once in that directory —
            that puts the files in place, and they can be read from there. If this interface
            was started in a different directory, pass the sketch's directory
            (`\(Command.name) mcp <directory>`).
            """
    }

    private func pretty(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "\(object)" }
        return text
    }
}
