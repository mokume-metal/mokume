// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// この実行を生んだ入力の世代。
///
/// 走らせている側 (作り直して差し替える道具) が環境変数で渡し、観測はそれを応答へ
/// そのまま載せる。読み手はこれを**不透明な識別子として等値比較だけ**行う — 中身の
/// 意味も長さも決めない。
///
/// これがあると、「保存した内容が反映されたか」を待ち時間ではなく**刻印の変化**で
/// 判定できる。壁時計で待つ判定は、遅い機械では古い絵を、速い機械では無駄待ちを掴む。
public enum SourceStamp {
    /// 環境変数の名前 (``StartupReads`` が正典)。
    static let environmentKey = StartupReads.sourceStamp.key

    /// いまの刻印。渡されていなければ `nil`。
    public static let current: String? = resolve(environment: ProcessInfo.processInfo.environment)

    static func resolve(environment: [String: String]) -> String? {
        guard let value = environment[environmentKey], !value.isEmpty else { return nil }
        return value
    }
}
