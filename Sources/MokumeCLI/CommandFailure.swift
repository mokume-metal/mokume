// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 道具が返す失敗。
///
/// 起こりうるものを列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **どの失敗にも「次に何をすればよいか」を書く** — 道具の失敗は人が読んで直すもの
/// なので、状態の報告だけでは足りない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum CommandFailure: Error, Equatable {
    case usage(String)
    case nameMissing
    case invalidName(String)
    /// 文字は使えるが、作ったパッケージが組めなくなる名前。`reason` は組めない理由 (英語の 1 文)。
    ///
    /// **``invalidName(_:)`` と分ける。** あちらは文字の種類の誤りで、直し方は文字を変えること。
    /// こちらは名前が mokume や Swift の名前と衝突していて、直し方は別の名前を選ぶこと
    /// ([#2310](https://github.com/mokume-metal/mokume/issues/2310))。
    case unusableName(name: String, reason: String)
    case directoryExists(path: String)
    case cannotCreate(path: String, reason: String)
    case templatesMissing
    case templateUnreadable(name: String)
    case packageNotFound(path: String)
    /// 渡された場所 (または作業ディレクトリ) が、ディレクトリとして在らない。
    ///
    /// **``packageNotFound(path:)`` と分ける。** そちらは `Package.swift` を求める口の失敗で、
    /// 窓口 (`mcp`) は `Package.swift` の無い場所でも起こされうる
    /// ([#2321](https://github.com/mokume-metal/mokume/issues/2321))。
    case directoryNotFound(path: String)
    case buildFailed(status: Int32)
    /// 走らせたスケッチが 0 以外で終わった。**道具の失敗ではない。**
    case sketchExited(status: Int32)
    /// 走らせたスケッチが、合図で落ちた (`fatalError` の SIGTRAP・SIGSEGV など)。**道具の失敗ではない。**
    ///
    /// **`sketchExited` と分ける。** `Process.terminationStatus` は合図で落ちた子には合図の番号を
    /// 返すので、まとめると SIGTRAP (5) を「exited with code 5」と言い、`exit(5)` で自分から終わった
    /// 回と見分けがつかない ([#2315](https://github.com/mokume-metal/mokume/issues/2315))。
    /// 終了コードはシェルの `$?` と同じ `128 + 番号` (``ChildEnding``)。道具自身が止めた回
    /// (``stopped(signal:)``) とは、止めたのが誰かで分かれる。
    case sketchSignalled(signal: Int32)
    /// 道具が終わりの合図を受け、走らせていたスケッチも止めて終わった。
    ///
    /// **`sketchExited` と分ける。** 子の終了コードは止めた合図で決まり、スケッチ自身の
    /// 事情を映さない — 後始末を済ませて終われば 0、済ませずに落ちれば 15 になる
    /// ([#1219](https://github.com/mokume-metal/mokume/issues/1219))。0 以外をそちらで名乗ると
    /// 「スケッチ自身の出力を読め」と読み違えさせる
    /// ([#1171](https://github.com/mokume-metal/mokume/issues/1171))。
    case stopped(signal: Int32)
    /// 書き出しが揃わなかった (`render`)。子は理由を名乗ってから 0 以外で終わっている。
    ///
    /// **`sketchExited` と分ける。** `render` の終了コードは「書けたか」を意味するので、
    /// 呼ぶ側が読みたいのはどこが欠けたかであって、スケッチの成否ではない
    /// ([#1282](https://github.com/mokume-metal/mokume/issues/1282))。
    ///
    /// **終わり方を持つ。** 子が合図で落ちた回を「exited with code N」と名乗らない (#2315)。
    case renderIncomplete(destination: String, ending: ChildEnding)
    /// 子は 0 で終わったが、書き出し先に頼んだものが揃っていなかった (`render`・
    /// [#2481](https://github.com/mokume-metal/mokume/issues/2481))。
    ///
    /// **``renderIncomplete(destination:ending:)`` と分ける。** あちらは子が自分で失敗を名乗った回で、
    /// こちらは子が何も言わずに終わったので、道具が書き出し先を見て気付いた。頼みを読まずに終わる
    /// 古い版の子 (道具と依存の版のずれ) がこちらに来る。
    case renderOutputShort(
        destination: String, expected: Int, shortfall: RenderRequest.Shortfall)
    case noExecutable(path: String)
    /// 起こそうとした実行ファイルが、起こす時点で無かった。
    ///
    /// **``noExecutable(path:)`` と分ける。** そちらは「宣言から走らせるものを決められない」
    /// 失敗で、案内は `Package.swift` を指す。こちらへ来る実行ファイルは宣言済みで、作り直しの
    /// 直後に建ったことを確かめたものだから、`Package.swift` を見直しても直らない — 消したのは
    /// 作り直しの外の誰かである。**この前提は呼び元 (`run`・`render`・`watch`) が作り直しの直後に
    /// 渡すことで成り立つ** (``RunCommand/launch(_:in:environment:forwarding:)``) ([#2522](https://github.com/mokume-metal/mokume/issues/2522))。
    case executableVanished(path: String)
    /// 作り直しは通ったのに、走らせるものが建っていない。
    ///
    /// **「ビルドが成功した」とは別の失敗である。** 置き場の計画が古いと道具立ては
    /// 「Build complete!」と言って実行ファイルを 1 つも作らないので、終了コードだけを
    /// 見ていると成功として通り、置き場に残っていた**別のスケッチの実行ファイル**を
    /// 起動することになる ([#1055](https://github.com/mokume-metal/mokume/issues/1055))。
    case productNotBuilt(product: String, path: String)
    case toolchainMissing(String)
    /// 子 (`swift`・スケッチ) を起こす場所が使えなかった — 無い・ディレクトリでない・入れない。
    /// **子が無いのではない。**
    ///
    /// `Process.run()` の失敗は、作業ディレクトリが無いときも実行ファイルが無いときも同じ形
    /// (`NSFileNoSuchFileError`) で、`toolchainMissing` に畳むと「Xcode を入れ直せ」と人を
    /// 遠ざけていた ([#2314](https://github.com/mokume-metal/mokume/issues/2314))。何が
    /// 使えないのかは、失敗の後に場所を stat し直して決める
    /// (``RunCommand/launchFailure(of:error:executableMissing:)``・``GivenPath/Presence``)。
    case placeUnusable(tool: String, place: String, presence: GivenPath.Presence)
    /// 場所はディレクトリで、実行ファイルも在るのに、子を起こせなかった (`ENOEXEC`・
    /// `EBADARCH`・`E2BIG`・`EAGAIN` など)。`reason` は OS の事情。
    ///
    /// **場所を疑わせない。** ``placeUnusable(tool:place:presence:)`` と文面を分けるのは、
    /// 場所に関わらない理由で「渡した場所を確かめよ」と言うと、確かめても直らない所へ人を
    /// 向かわせるからである。
    case cannotLaunch(tool: String, place: String, reason: String)
    /// 答えを読むために道具立てへ聞いたが、道具立てが答えなかった (0 以外で終わった・
    /// 何も答えなかった)。`command` は打ったもの。
    ///
    /// **宣言 (`Package.swift`) の不備として名乗らない。** `--show-bin-path` の空の答えを
    /// ``noExecutable(path:)`` と読んでいた頃は、道具立てが `-c Release` を断った回に
    /// 「Package.swift に実行ファイルが無い」と言っていた
    /// ([#2316](https://github.com/mokume-metal/mokume/issues/2316))。原因が道具立てなのに
    /// 宣言を疑わせる形は、`env` の 127 で塞いだ #1157 と同じである。
    ///
    /// **理由は道具立てが標準エラーで名乗っている** (聞く側は愚痴を混ぜずに流す — #731)。
    /// 「上を読め」とは言わない: 見張りはこの文面を記録 (`BuildReport.output`) に載せ、窓口の
    /// 読み手には端末の「上」が無い。打ったものを名乗るので、打ち直せば同じ理由が読める。
    case toolchainFailed(command: String, status: Int32)
    /// 道具立ては 0 で答えたが、答えが読める形をしていなかった。`command` は打ったもの。
    ///
    /// **``toolchainFailed(command:status:)`` と分ける** (終了コード 0 の「失敗」と名乗らない)。
    /// 道具立てが出力の形を変えた日に起きる。**宣言 (`Package.swift`) の不備として名乗らない** (#2575)。
    case declarationUnreadable(command: String)
    /// 作り直しを途中で止めると決めた後に、次の `swift` を起こそうとした。
    ///
    /// **人へ届く失敗ではない。** 止めるのは見張りが終わるときだけで、この失敗を受ける
    /// 作り直しの続きはもう誰にも読まれない — それでも成功の顔はさせない
    /// ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    case rebuildStopped

    /// 資材の置き場があるのに、パッケージが宣言していない。
    case resourcesNotDeclared(directory: String)
    /// 束ねようとしたが、名乗りが置かれていない。
    case identityMissing(path: String)
    /// 名乗りは在るが、読める形をしていない。
    case identityUnreadable(path: String)
    /// 名乗りに、名乗れる中身が揃っていない。
    case identityIncomplete(path: String, missing: [String])
    /// 名乗りの `name` に、ファイル名にできないもの (`/`・NUL) がある。
    ///
    /// **組み立ての前に断る** ([#2309](https://github.com/mokume-metal/mokume/issues/2309)・
    /// メンテナの決定 = 案 B)。`name` は表示名であり、包みのファイル名 (`<name>.app`) と開き方の
    /// 紙の名前にもなる。`/` があると `--out` の下に余計なディレクトリを作って途中で止まり、
    /// `..` と組むと `--out` の外の `.app` を消していた。
    case identityNameUnusable(path: String, name: String)
    /// 名乗りの `name` が、ファイル名にするには長すぎる。`length` は
    /// ``AppIdentity/fileNameLength(of:)`` で数えた長さ。
    ///
    /// **組み立ての前に断る** ([#2501](https://github.com/mokume-metal/mokume/issues/2501))。
    /// `name` は包み (`<name>.app`) と開き方の紙のファイル名にもなり、長いほうの紙が上限を越えると、
    /// ビルドと署名の後で紙が書けずに止まり、署名済みの `.app` が残っていた。
    case identityNameTooLong(path: String, name: String, length: Int)
    /// カメラを使うスケッチなのに、名乗りに許可の文言が無い。
    ///
    /// **束ねずに止める。** 出来た包みは、触れた時点で OS に止められる — 作った手元では
    /// 動くので、気付くのは配った先になる ([ADR-0042] 決定 8)。
    ///
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    case cameraUsageMissing(path: String, files: [String])
    /// マイクを使うのに、許可を求める文言が書かれていない。
    case microphoneUsageMissing(path: String, files: [String])
    /// 宣言された資材の包みが、組み上がりに入っていない。
    case bundledResourceMissing(name: String, path: String)
    /// 区画へ要求を置けなかった。
    case facetUnwritable(path: String, reason: String)
    /// 署名に失敗した。
    case codesignFailed(status: Int32)

    /// 道具が返す終了コード。
    ///
    /// **`run` だけが子の終了コードを引き継ぐ。** 呼ぶ側が見ているのは道具の成否では
    /// なくスケッチの成否なので、そのまま通す。ただし**合図で落ちた子には終了コードが無い**
    /// ので、シェルの `$?` と同じ `128 + 番号` にする (下)。ほかは道具自身の失敗なので 1 でよい。
    ///
    /// **合図で止めた回は慣習の `128 + 番号` を返す。** 止めた側が読みたいのは
    /// 「合図で終わった」ことで、スケッチの成否ではない。スケッチが合図で落ちた回
    /// (``sketchSignalled(signal:)``) も同じ値で、シェルで子を直に走らせたときの `$?` と揃う。
    var exitCode: Int32 {
        switch self {
        case .sketchExited(let status): status
        case .sketchSignalled(let signal): 128 + signal
        case .stopped(let signal): 128 + signal
        default: 1
        }
    }

    var message: String {
        switch self {
        case .usage(let text):
            text
        case .nameMissing:
            "The sketch needs a name: \(Command.name) new <name>"
        case .invalidName(let name):
            """
            \(name.isEmpty ? "The name is empty" : "That name has characters a sketch cannot use: \(name)")
            Use letters, digits, hyphens and underscores, and start with a letter
            """
        case .unusableName(let name, let reason):
            """
            That name would make a sketch that does not build: \(name)
            \(reason)
            Pick another name, for example my-\(name.lowercased())
            """
        case .directoryExists(let path):
            "Already there: \(path)\nPick another name, or remove that one first"
        case .cannotCreate(let path, let reason):
            "Could not create: \(path)\n\(reason)"
        case .templatesMissing:
            """
            Cannot find the templates.
            The tool is two pieces that belong together — the executable and
            mokume_MokumeCLI.bundle — and the templates live in the second one.
            Check that the install put both in place, not just one
            """
        case .templateUnreadable(let name):
            "Cannot read the template: \(name)"
        case .packageNotFound(let path):
            """
            Cannot find a sketch here: \(path)
            Point at a directory that has Package.swift (\(Command.name) new <name> makes one)
            """
        case .directoryNotFound(let path):
            """
            No such directory: \(path)
            Point at a directory that exists
            """
        case .resourcesNotDeclared(let directory):
            """
            \(directory) holds assets, but Package.swift does not declare them.
            Running as is will build fine and only fail to read them once the sketch is
            drawing (nothing appears, and the drawing code takes the blame). Add one line
            to the target:

              resources: [.copy("\(ResourceDeclaration.directoryName)")],

            If that directory is not meant to ship as assets, rename it.
            """
        case .identityMissing(let path):
            """
            Bundling needs an identity. There is none at: \(path)

            \(AppIdentity.example)

            The templates do not ship one. A sketch runs without it, but shipping without
            it causes trouble later: the identifier is the key that granted permissions
            hang from, so leaving a placeholder in place mixes one work's permissions with
            another's. Give every work its own values.
            """
        case .identityUnreadable(let path):
            """
            Cannot read the identity: \(path)
            Check that it is well-formed JSON:

            \(AppIdentity.example)
            """
        case .identityIncomplete(let path, let missing):
            """
            The identity is missing something: \(path)
            Absent or empty: \(missing.joined(separator: " / "))

            \(AppIdentity.example)
            """
        case .identityNameUnusable(let path, let name):
            """
            The name in the identity cannot contain "/" (or a NUL character): \(name)
            In: \(path)
            The name is also the file name of the bundle (<name>.app) and of the note beside it,
            and "/" would put them in another folder. Pick a name without "/".
            """
        case .identityNameTooLong(let path, let name, let length):
            """
            The name in the identity is too long to be a file name: it is \(length) long, \
            and it can be at most \(AppIdentity.maximumNameLength): \(name)
            In: \(path)
            The name is also the file name of the bundle (<name>.app) and of the note beside it.
            The note's name is \(AppIdentity.fileNameLimit - AppIdentity.maximumNameLength) longer \
            than the name, and a file name on APFS can be at most \(AppIdentity.fileNameLimit) units long.
            Length is counted in UTF-16 units of the form macOS hands to the file system, with marks
            split off from their letters: a letter with an accent (é) or a kana with a voiced mark
            counts as 2, a letter with two marks (ệ) as 3, a Hangul syllable as 2 or 3, an emoji as 2,
            a flag as 4, and a family emoji joined with zero-width joiners as 11.
            Pick a shorter name.
            """
        case .cameraUsageMissing(let path, let files):
            """
            The sketch opens the camera, but the identity has no text for the permission prompt: \(path)
            Opened in:
            \(files.map { "  \($0)" }.joined(separator: "\n"))

            Add one line saying why the work needs it:

              "cameraUsage": "Grain uses the camera to draw what it sees"

            Without it, macOS stops the bundled app the moment it first touches the camera:
            the other side gets no prompt and no drawing, and nothing that points at why.
            The text is what the prompt shows to whoever opens the app, so write it for them.
            """
        case .microphoneUsageMissing(let path, let files):
            """
            The sketch opens the microphone, but the identity has no text for the permission prompt: \(path)
            Opened in:
            \(files.map { "  \($0)" }.joined(separator: "\n"))

            Add one line saying why the work needs it:

              "microphoneUsage": "Grain listens to the room to move the drawing"

            Without it, macOS stops the bundled app the moment it first touches the microphone:
            the other side gets no prompt and no sound, and nothing that points at why.
            The text is what the prompt shows to whoever opens the app, so write it for them.
            """
        case .bundledResourceMissing(let name, let path):
            """
            A declared asset bundle did not make it into the build: \(name)
            Where it belongs: \(path)

            Ship this and the other side gets no drawing and nothing that points at why.
            Build again; if it still does not appear, check that the declaration in
            Package.swift and the name of what was built agree.
            """
        case .facetUnwritable(let path, let reason):
            """
            Could not place the request: \(path)
            \(reason)

            Check that the directory can be written to and that the disk has room.
            MOKUME_WORK_DIR moves it (pass the same value to the runner and to the
            interface, or the two look in different places)
            """
        case .codesignFailed(let status):
            """
            Signing failed (exit code \(status)). Read the output above
            Without a signature, another machine refuses to open it at all
            """
        case .rebuildStopped:
            "The rebuild was stopped partway, because watching ended"
        case .buildFailed(let status):
            "The build failed (exit code \(status)). Read the output above"
        case .sketchExited(let status):
            """
            The sketch exited with code \(status).
            This is not a failure the tool added — the reason is in the sketch's own output
            """
        case .sketchSignalled(let signal):
            """
            The sketch was ended by signal \(ChildEnding.describe(signal: signal)).
            This is not a failure the tool added — the reason is in the sketch's own output
            """
        case .stopped(let signal):
            "Stopped by signal \(signal) — the running sketch was stopped too"
        case .renderIncomplete(let destination, let ending):
            """
            Rendering did not complete: \(destination) is missing frames or was not written.
            The sketch said why above — it \(ending.phrase)
            """
        case .renderOutputShort(let destination, let expected, let shortfall):
            """
            Rendering did not complete: \(Self.describe(shortfall, expected: expected, destination: destination))
            The sketch itself ended without an error. A sketch built with another version of \
            mokume than this tool does not read the request and writes nothing — build it again
            """
        case .noExecutable(let path):
            """
            Cannot find anything to run: \(path)
            Check that Package.swift declares an executable in products
            """
        case .executableVanished(let path):
            """
            The sketch's executable was there right after the build, but it is gone now: \(path)
            Something removed it in between (a clean, or another build). Run it again
            """
        case .productNotBuilt(let product, let path):
            """
            The build succeeded, but \(product) was never built: \(path)
            A stale plan left in the build directory can do this — remove that directory
            and try again
            """
        case .toolchainMissing(let tool):
            "Cannot find \(tool). Install the Xcode command line tools"
        case .placeUnusable(let tool, let place, let presence):
            """
            Could not start \(tool) in \(place): \(presence.reason)
            This does not mean \(tool) is missing. Check the place you gave \
            (a relative path starts from where you ran this)
            """
        case .cannotLaunch(let tool, let place, let reason):
            "Could not start \(tool) in \(place): \(reason)"
        case .declarationUnreadable(let command):
            """
            The toolchain answered, but what it said could not be read: \(command)
            A toolchain that changed its output format can do this; run that command in the sketch's directory to see what it prints
            """
        case .toolchainFailed(let command, let status):
            """
            The toolchain did not answer (exit code \(status)): \(command)
            It said why on standard error; run that command in the sketch's directory to see it again
            """
        }
    }

    /// ``renderOutputShort(destination:expected:shortfall:)`` の、何が足りなかったかの 1 行。
    private static func describe(
        _ shortfall: RenderRequest.Shortfall, expected: Int, destination: String
    ) -> String {
        switch shortfall {
        case .notWritten:
            "nothing was written to \(destination) by this run (\(expected) frames were asked for)"
        case .unreadable:
            "\(destination) is there but cannot be read as a movie (\(expected) frames were asked for)"
        case .frames(let found):
            "only \(found) of \(expected) frames are in \(destination)"
        }
    }
}
