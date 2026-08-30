// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 同梱している資源 (シェーダの断片) の包みを探す。
///
/// ## なぜ道具立ての用意した口だけに頼らないか
///
/// 道具立てが生成する `Bundle.module` が見るのは **`Bundle.main.bundleURL` の直下 1 箇所**
/// だけで、そこに無ければ**組み上げた機械の作業用ディレクトリの絶対パス**へ落ちる。素の
/// 実行ファイルとして走らせている限りは前者で当たるので、この作りは開発中は一度も
/// 表に出ない。
///
/// 表に出るのは配ったときである。包み (`.app`) の中では `Bundle.main.bundleURL` が包み
/// そのものを指すので、慣例どおり `Contents/Resources/` へ資源を置くと当たらず、絶対パスの
/// ほうへ落ちる — **作者の手元では動き、配った先だけで落ちる**という、いちばん見つけにくい
/// 壊れ方をする。
///
/// [ADR-0029] 決定 4 は責務の線を「**束ねた中で資材が見つかること = ライブラリ**」と引いた。
/// 束ねる側は起動時の解決規則を持たないので、外から後付けで直せない。だからここで解決する。
///
/// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
nonisolated enum ModuleResources {
    /// 包みの名前。道具立てが `<パッケージ>_<ターゲット>` の形で作る。
    static let bundleName = "mokume_MokumeCore"

    /// 同梱の資源を 1 つ探す。
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        resolve(
            name: name, extension: ext,
            neighbourhood: Bundle.main.bundleURL, resources: Bundle.main.resourceURL,
            lastResort: { Bundle.module.url(forResource: $0, withExtension: $1) })
    }

    /// 探す並びを順に見る (起点と最後の 1 段を渡せる形)。
    ///
    /// **最後の 1 段は道具立ての口に譲る。** 開発中と検査では、包みが組み上げた場所に
    /// 置かれていて、その場所を知っているのは道具立てだけである。ここが探す並びに 1 つも
    /// 包みが無かったときに限って譲るので、**いま通っている経路の振る舞いは変わらない**。
    ///
    /// **ただし配られた形では譲らない。** 道具立ての口が指す最後の行き先は「組み上げた
    /// 機械の絶対パス」で、配った先には無い。譲ると、そこで止まるのではなく**作者の
    /// ディレクトリを名指しして落ちる** — 受け取った人にとって意味の無い場所を指す
    /// うえ、こちらの名乗り (資源が無い) に変えられなくなる。
    static func resolve(
        name: String, extension ext: String, neighbourhood: URL?, resources: URL?,
        lastResort: (String, String) -> URL?
    ) -> URL? {
        let bundles = candidates(neighbourhood: neighbourhood, resources: resources)
            .compactMap(Bundle.init(url:))
        for bundle in bundles {
            if let found = bundle.url(forResource: name, withExtension: ext) { return found }
        }
        guard bundles.isEmpty, !isPackaged(neighbourhood) else { return nil }
        return lastResort(name, ext)
    }

    /// 配るために束ねられた形か。
    static func isPackaged(_ neighbourhood: URL?) -> Bool {
        neighbourhood?.pathExtension == "app"
    }

    /// 包みを探す場所を、見る順に並べる (起点を渡せる形)。
    ///
    /// 起点を渡せるのは、**包みの中での解決を検査から確かめるため**。組み上げた並びを
    /// 起点にして、ここが返す並びに入っていることを見る。
    ///
    /// 素の実行ファイルでは 2 つの起点が同じ場所を指すので、同じ道は 1 度しか並べない。
    static func candidates(neighbourhood: URL?, resources: URL?) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []
        for root in [neighbourhood, resources].compactMap({ $0 }) {
            let url = root.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            urls.append(url)
        }
        return urls
    }
}
