// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 天気の JSON を URL から読んで色を塗り、星座の XML をファイルから読んで描く
/// ([#2070] の作例 1・2)。
///
/// 左の 3 枚は、街ごとの天気の API の URL を `loadJSONObject` で読んだもの。応答の入れ子
/// (`main.temp`) から気温を取り出し、寒いほど青く、暑いほど橙に塗る。**3 枚目の URL は
/// 届かない** — 灰色に塗り、左下の隅に理由 (投げられた `DataFailure` の 1 文) を出す。
///
/// 右の星座は、`data/constellation.xml` を `loadXML` で読んだもの。`star` の子を書かれた
/// 順に取り出し、属性 (`x`・`y`・`size`) を数で読んで、星と星を結ぶ線を描く。
///
/// **天気は setup の中で同期版で読む。** 待たない版 (`requestJSONObject`) の結果は、書き出しの
/// 絵では受け取る番が回らない (`table-and-text` の「読み直している…」と同じ)。色と理由を
/// 書き出しと台帳の絵に残すため、ここは同期版にした。待たない版 2 本は、下の 1 行で同じ
/// URL とファイルを読み直す (窓で走らせれば、起動して間もなく結果に変わる)。
///
/// [#2070]: https://github.com/mokume-metal/mokume/issues/2070
final class JSONAndXML: Sketch {
    var settings = SketchSettings(width: 1200, height: 560, title: "json and xml")

    /// 天気を読む街。URL は予約済みの名前 (`weather.example`) で、応答は ``CannedWeather`` が返す。
    private static let cities: [(label: String, url: String)] = [
        ("札幌", "https://weather.example/sapporo"),
        ("那覇", "https://weather.example/naha"),
        ("どこにも無い街", "https://weather.example/atlantis"),
    ]

    /// 街ごとに読んだ気温。読めなかった街は `nil` で、`reasons` に理由がある。
    private var temps: [Float?] = []
    private var reasons: [String] = []
    /// 星座。読めなければ `nil` のまま (枠だけが出る)。
    private var sky: XML?
    /// 待たない口で読み直した結果。**届くまでは `nil`**
    private var reread: String?

    /// 天気の帯の場所。
    private static let left: Float = 40
    private static let stripWidth: Float = 580
    private static let stripHeight: Float = 130
    private static let stripTops: [Float] = [70, 215, 360]
    /// 星座の枠の場所 (左上)。XML の座標はここからの位置。
    private static let skyLeft: Float = 660
    private static let skyTop: Float = 70

    func setup() {
        _ = CannedWeather.installed
        for city in Self.cities {
            do {
                let weather = try loadJSONObject(city.url)
                temps.append(weather.getJSONObject("main").getFloat("temp"))
                reasons.append("")
            } catch {
                temps.append(nil)
                reasons.append("\(error)")
            }
        }
        sky = try? loadXML(Self.data("constellation.xml"))

        // 同じ URL とファイルを、待たない口で読み直す。待つのは Task の仕事で、届くまでは
        // 下の draw() が「読み直している…」と出す
        Task {
            let weather = try? await requestJSONObject(Self.cities[0].url)
            let stars = try? await requestXML(Self.data("constellation.xml"))
            let temp = weather?.getJSONObject("main").getFloat("temp") ?? .nan
            let count = stars?.getChildren("star").count ?? 0
            reread = "\(Self.cities[0].label) \(String(format: "%.1f", temp))°C・星 \(count) 個"
        }
    }

    func draw() {
        background(23, 26, 31)

        noStroke()
        fill(220, 222, 228)
        textSize(16)
        text("天気の JSON を URL から読む (loadJSONObject)", Self.left, 44)
        text("星座の XML をファイルから読む (loadXML)", Self.skyLeft, 44)

        for (i, city) in Self.cities.enumerated() where i < temps.count {
            drawStrip(city.label, city.url, temps[i], reasons[i], top: Self.stripTops[i])
        }
        drawSky()

        noStroke()
        fill(150, 154, 162)
        textSize(13)
        if let reread {
            text("待たない口 (requestJSONObject / requestXML) で読み直した: \(reread)", Self.left, 536)
        } else {
            text("待たない口 (requestJSONObject / requestXML) で読み直している…", Self.left, 536)
        }
    }

    /// 天気の帯 1 枚。気温が読めれば寒色から暖色の間で塗り、読めなければ灰色に塗って隅に理由を出す。
    private func drawStrip(_ label: String, _ url: String, _ temp: Float?, _ reason: String, top: Float) {
        noStroke()
        if let temp {
            let warmth = constrain(norm(temp, -10, 35), 0, 1)
            fill(lerp(70, 240, warmth), lerp(130, 140, warmth), lerp(220, 60, warmth))
        } else {
            fill(90, 94, 102)
        }
        rect(Self.left, top, Self.stripWidth, Self.stripHeight)

        fill(255, 255, 255)
        textSize(18)
        text(label, Self.left + 16, top + 32)
        if let temp {
            textSize(44)
            text(String(format: "%.1f°C", temp), Self.left + 360, top + 84)
        }
        fill(255, 255, 255, 190)
        textSize(12)
        text(url, Self.left + 16, top + 56)
        if temp == nil {
            // 届かないときは、画面ではなく帯の左下の隅に理由を出す
            text(reason, Self.left + 16, top + Self.stripHeight - 14)
        }
    }

    /// 星座。星を書かれた順に線で結び、星は大きさの属性の直径で描く。
    private func drawSky() {
        noStroke()
        fill(12, 16, 32)
        rect(Self.skyLeft, Self.skyTop, 500, 420)
        guard let sky else { return }
        let stars = sky.getChildren("star")

        stroke(120, 140, 200, 140)
        strokeWeight(1.5)
        for (i, star) in stars.enumerated() where i > 0 {
            let previous = stars[i - 1]
            line(
                Self.skyLeft + previous.getFloat("x"), Self.skyTop + previous.getFloat("y"),
                Self.skyLeft + star.getFloat("x"), Self.skyTop + star.getFloat("y"))
        }

        noStroke()
        for star in stars {
            let x = Self.skyLeft + star.getFloat("x")
            let y = Self.skyTop + star.getFloat("y")
            let size = star.getFloat("size")
            fill(170, 190, 255, 50)
            circle(x, y, size * 2.6)
            fill(240, 244, 255)
            circle(x, y, size)
        }
    }

    /// 読むファイルの場所。**普通のスケッチには要らない** — `loadXML("data/constellation.xml")`
    /// と書けば、作業ディレクトリと束ねた資材から探す。参照スケッチは窓・書き出し・台帳の検査の
    /// 3 つの入口から走り、作業ディレクトリが入口ごとに違うので、このファイルの隣を名指しする
    /// (`table-and-text` と同じ)。
    private static func data(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("data").appendingPathComponent(name).path
    }
}

/// `weather.example` への要求に、置いた応答を返す。**普通のスケッチには要らない** — 本物の
/// 天気の API の URL を渡せばよい。
///
/// 参照スケッチは検査 (台帳) からも走るので、外のネットワークに出てはいけない (#2070)。
/// 予約済みの名前 (`.example`・RFC 2606) への要求をここで横取りし、街ごとの応答を返す。
/// 置いていない道には 404 で答える (3 枚目の帯が「届かない」になる)。
nonisolated final class CannedWeather: URLProtocol, @unchecked Sendable {
    /// 道ごとの応答。形は OpenWeatherMap の応答に倣った (気温は `main.temp`)。
    private static let bodies: [String: String] = [
        "/sapporo": #"{"name": "Sapporo", "main": {"temp": -3.5, "humidity": 71}}"#,
        "/naha": #"{"name": "Naha", "main": {"temp": 27.5, "humidity": 78}}"#,
    ]

    /// 登録は 1 度だけ。
    static let installed: Bool = {
        URLProtocol.registerClass(CannedWeather.self)
        return true
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "weather.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.bodies[url.path()]
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? #"{"message": "city not found"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
