// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチが依存として解決している mokume の版。
///
/// ## なぜ 1 箇所に置くのか
///
/// 読み手は 2 つある — 版ごとの資産 (公開 API の一覧) を取りに行く側と、動かないときの
/// 切り分けの口である。**それぞれが自分で読むと、`Package.resolved` の形が変わった日に
/// 片方だけが追随する。**
///
/// ## なぜ切り分けの口が要るのか
///
/// 起動の瞬間に決まるものの一覧は「依存している mokume はこの面を持たない」とまで名乗る
/// ([DependencyFacets]) のに、**いくつなのかを言わない**。読み手は持っていないことは分かるが、
/// どこまで上げればよいかを知れない ([#684](https://github.com/mokume-metal/mokume/issues/684))。
///
/// ## 断定できないときは断定しない
///
/// パスで指した依存には pin が無いので `nil` を返す。開発中はこの形になる。
///
/// **main actor には置かない。** 見張りの作り直しは巡回とは別の糸から進むので、
/// そこから辿るものが隔離されていると待ちが main actor へ戻ってしまう
/// ([#1067](https://github.com/mokume-metal/mokume/issues/1067)・ADR-0010 決定 4)。
nonisolated enum DependencyVersion {
    /// 依存の識別子。
    static let identity = "mokume"

    /// 何で固定されているか。
    ///
    /// **版と改訂を分ける。** 版が読めないことには 2 つの意味があり (枝や改訂で固定した /
    /// そもそもまだ解決されていない)、混ぜるとビルドの置き場の鍵が**違う改訂の mokume を
    /// 同じ部屋へ入れる** — 実測で、そうすると互いを作り直させ続けて増分ビルドが 1.6 秒
    /// から 8 秒へ落ちる ([#1055](https://github.com/mokume-metal/mokume/issues/1055))。
    enum Pin: Equatable {
        /// 版で固定されている。
        case version(String)
        /// 枝または改訂で固定されている。
        case revision(String)
    }

    /// 依存の版が、何から分かるか (分からないなら、なぜか)。
    ///
    /// **「版が引けない」には、打つ手の違う理由がある** (#3419)。`mokume new` 直後の未解決を
    /// 「パスで指している」と決めつけると、利用者を本体の開発手順へ送ってしまう。確かめられる事実
    /// (`Package.swift` と `Package.resolved` の有無・pin の種類) だけで分け、分からない境目は
    /// 断定しない。
    enum State: Equatable {
        /// 版で固定されている。
        case version(String)
        /// 枝または改訂で固定されている。リリースの版ではないので、公開 API の一覧の資産が無い。
        case revision(String)
        /// `Package.swift` はあるが `Package.resolved` が無い。**作ったばかりのスケッチの形。**
        /// パスで指している場合も、解決するまでは同じ形なので区別できない。
        case unresolved
        /// `Package.resolved` は読めたが `mokume` の pin が無い。パス依存は pin を持たないので、
        /// 本体の開発のときもこの形になる (mokume に依存していない場合も)。
        case notPinned
        /// `Package.resolved` はあるが読めない (壊れている・読み取れない・知らない形式)。
        /// **pin が無いのか読めないだけなのかが分からない**ので、パスで指しているとは言えない。
        case unreadable
        /// pin は読めたが、版・改訂の文字列が名前に使える形でない (手で書き換えた・壊れた `Package.resolved`)。
        /// **弾いた値を持つ** — 案内が「どの値が・どう違うか」を名乗れる (``isVersion(_:)``・``isRevision(_:)``)。
        /// SwiftPM 自身もこの `Package.resolved` を壊れたものとして断る (書き直しはしない)。
        case malformed(Pin)
        /// `Package.swift` が無い。スケッチの場所で立っていない。
        case noPackage
    }

    /// 依存の版の状態。pin が読めればそれが先で、読めなければ置かれているファイルから分ける。
    ///
    /// **pin の文字列が版・改訂の形でないものは `.malformed` にする** (``isVersion(_:)``・``isRevision(_:)``)。
    /// 名前に使うと `/` や `..` で置き場の外を指すので、鍵にもパスにも使わない。
    static func state(forPackageAt package: URL) -> State {
        switch lookup(forPackageAt: package) {
        case .pinned(.version(let version)): return .version(version)
        case .pinned(.revision(let revision)): return .revision(revision)
        case .malformed(let pin): return .malformed(pin)
        case .absent: break
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: package.appendingPathComponent("Package.swift").path)
        else { return .noPackage }
        let resolved = package.appendingPathComponent("Package.resolved")
        guard manager.fileExists(atPath: resolved.path) else { return .unresolved }
        // pin が引けなかったのは、読めたうえで無いのか、そもそも読めないのかのどちらか
        return SwiftPM.read(SwiftPM.Resolved.self, at: resolved) == nil ? .unreadable : .notPinned
    }

    /// 解決された版。読めなければ `nil`。
    ///
    /// 形式は SwiftPM の版 2 以降 (`pins` が根にある) を読む。ひな形は tools-version 6.2 を
    /// 宣言するので、それより古い形式は書かれない。
    static func resolved(forPackageAt package: URL) -> String? {
        if case .version(let version) = pin(forPackageAt: package) { return version }
        return nil
    }

    /// 何で固定されているか。固定が読めなければ (形が版・改訂でないものも) `nil`。
    static func pin(forPackageAt package: URL) -> Pin? {
        if case .pinned(let pin) = lookup(forPackageAt: package) { return pin }
        return nil
    }

    /// pin の引き方。**版・改訂の文字列は、名前に使う前にここで検める。**
    private enum Lookup {
        case pinned(Pin)
        /// `mokume` の pin が無い (`Package.resolved` が無い・読めない場合も)。
        case absent
        /// pin はあるが、版・改訂の形でない (手で書き換えた・壊れた `Package.resolved`)。弾いた値を持つ。
        case malformed(Pin)
    }

    private static func lookup(forPackageAt package: URL) -> Lookup {
        let url = package.appendingPathComponent("Package.resolved")
        guard let resolved = SwiftPM.read(SwiftPM.Resolved.self, at: url) else { return .absent }
        // 版が在るのに形が違うなら、改訂へ落とさず弾く (版で固定した pin は改訂も持つ)
        if let version = resolved.version(of: identity) {
            return isVersion(version) ? .pinned(.version(version)) : .malformed(.version(version))
        }
        if let revision = resolved.revision(of: identity) {
            return isRevision(revision) ? .pinned(.revision(revision)) : .malformed(.revision(revision))
        }
        return .absent
    }

    /// 名前の 1 段にしてよい文字列の長さの上限 (UTF-8 のバイト数)。ファイル名は 255 バイトまでで、
    /// `mokume-api-v<版>.md` や置き場の名前の枠を足しても収まる値。版は `1.2.3`・`0.5.0-beta.1` の長さ、
    /// 改訂は 40 字 (SHA-256 でも 64 字) なので、これを超えるものは実在の値ではない。
    static let maximumLength = 128

    /// 版の形か。**先頭が数字で、数字・`.`・`-`・`+`・英字 (ASCII) だけ、``maximumLength`` 字まで**
    /// (`1.2.3`・`0.5.0-beta.1`・`1.0.0+build`)。
    ///
    /// 版は `mokume-api-v<版>.md` や置き場の名前の 1 段、資産の URL に入る。`/`・`..`・空・制御文字を通すと、
    /// 取り置きや置き場が `.mokume/reference/` や共有の根の外へ出るので、この形でない文字列は版として扱わない。
    /// **名前を作る口はどれもこの判定を通る** (``BuildDirectory/keySegment(pin:)``・取り置きの名前・資産の URL)。
    /// 道具の版 (``ToolVersion``・Homebrew の revision の `_` を許す) とは別の物で、写しではない。
    static func isVersion(_ text: String) -> Bool {
        guard text.utf8.count <= maximumLength, let first = text.unicodeScalars.first,
            ("0"..."9").contains(first)
        else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || scalar == "." || scalar == "-" || scalar == "+"
        }
    }

    /// 改訂の形か。**16 進数の字だけ、``maximumLength`` 字まで** (リポジトリの改訂)。名前の 1 段
    /// (`rev-<先頭 12 字>`) に入るので、版と同じ理由で検める。
    static func isRevision(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumLength
            && text.unicodeScalars.allSatisfy {
                ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
            }
    }

    /// 弾いた値を、案内に出せる形にする。**制御文字を逃がし (`\u{1b}`)、長ければ切る** — 端末を乱さず、
    /// 長い値で案内が埋まらない。
    static func shown(_ text: String, limit: Int = 40) -> String {
        var shown = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count == limit { return shown + "…" }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate:
                shown += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                shown.unicodeScalars.append(scalar)
            }
            count += 1
        }
        return shown
    }

    /// 弾いた pin を、案内の文にする (`version `../../x``)。
    static func describe(_ pin: Pin) -> String {
        switch pin {
        case .version(let version): "version `\(shown(version))`"
        case .revision(let revision): "revision `\(shown(revision))`"
        }
    }

    /// 弾いた理由の文 (どんな形なら受けるか)。
    static func rule(for pin: Pin) -> String {
        switch pin {
        case .version:
            "a version must start with a digit and contain only digits, letters, `.`, `-` and `+` (at most \(maximumLength) characters)"
        case .revision:
            "a revision must be hexadecimal digits only (at most \(maximumLength) characters)"
        }
    }
}
