// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 読んだ記録 (`Schemas/replay-record.schema.json`・#3571)。流す側 (``ReplayPlayer``) が当てる値と照らす値を持つ。
///
/// **読めない記録は流さない。** 版が違う・完成の印が無い・この mokume が知らない入力を持つ記録は、理由を 1 文で
/// 返して断る (``Unreadable``)。流してから食い違ったと名乗ると、記録の誤りと作品の変化の見分けが付かない。
/// 道具 (`mokume replay`) もビルドの前に同じ型で読み、断る理由を先に言う。
package struct ReplayRecord {
    /// 読めない理由 (1 文・英語)。
    package struct Unreadable: Error, Equatable {
        package let reason: String
    }

    /// `advance()` 1 回ぶんの記録 (記録の `steps` の 1 項目)。
    struct Step {
        /// 入力を配った `advance()` の通し番号 (0 から)。
        let step: Int
        /// その回の終わりのフレーム番号。
        let frame: Int
        /// その回がフレームを描いたか。
        let drew: Bool
        /// その回に届いた入力 (届いた順)。
        let inputs: [InputEvent]
        /// その回の前に外から書かれたつまみの値 (収めた後の値)。
        let params: [NamedParamValue]
        /// 時刻を指定した観測の秒。
        let observeTime: Float?
        /// その回に差し出された値。**照らす相手。**
        let expose: [String: ParamValue]
        /// その枚の画素のハッシュ。60 フレームごとの描いた枚にだけある。
        let pixelHash: String?
    }

    /// 記録の識別子。
    package let id: String
    /// フレームの時計の刻み (1 秒あたりの枚数)。
    package let frameRate: Int
    /// 画素のハッシュを取った絵の大きさ。
    package let width: Int
    package let height: Int
    /// ウィンドウに出しながら録ったか。
    package let window: Bool
    /// 最初の枚の作者の時計の秒と、止めているか。
    let startSeconds: Double
    let startPaused: Bool
    /// `setup()` の前のつまみの値 (宣言した順)。
    let startParams: [NamedParamValue]
    /// 記録された回 (通し番号の順)。何も起きなかった止めた回は無い (番号の欠け)。
    let steps: [Step]
    /// 記録が名乗った、再現を保証しない理由 (記録の順)。
    package let unreproducible: [String]
    /// 最後に描いた枚の番号とハッシュ。
    let last: (frame: Int, pixelHash: String)?

    /// ファイルから読む。**読めなければ理由つきで投げる。**
    package static func read(from url: URL) throws(Unreadable) -> ReplayRecord {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Unreadable(reason: "Could not read \(url.path): \(Diagnostics.reason(error))")
        }
        return try decode(data, from: url.path)
    }

    /// 中身から読む。`place` は理由の文面に入れる名前。
    static func decode(_ data: Data, from place: String) throws(Unreadable) -> ReplayRecord {
        let decoder = JSONDecoder()
        // 記録は有限でない数を文字列で書く (``ReplayRecorder``)
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        // 版と完成の印を先に見る — 版の違う記録の中身を、この版の形として読み違えない
        let head: Head
        do {
            head = try decoder.decode(Head.self, from: data)
        } catch {
            throw Unreadable(reason: "\(place) is not a record of a run: \(Diagnostics.reason(error))")
        }
        guard head.schemaVersion == ReplayRecorder.schemaVersion else {
            let found = head.schemaVersion.map { "version \($0)" } ?? "no version"
            throw Unreadable(
                reason: "\(place) has \(found), and this mokume reads records of version "
                    + "\(ReplayRecorder.schemaVersion)")
        }
        guard head.complete == true else {
            throw Unreadable(
                reason: "\(place) is not a finished record (it has no \"complete\": true, so the run that wrote "
                    + "it did not end cleanly)")
        }
        let file: File
        do {
            file = try decoder.decode(File.self, from: data)
        } catch {
            throw Unreadable(reason: "\(place) is not a record this mokume reads: \(Diagnostics.reason(error))")
        }
        guard file.clock.kind == "frames", file.clock.frameRate > 0 else {
            throw Unreadable(reason: "\(place) is not on the frame clock, so it cannot be replayed")
        }
        var steps: [Step] = []
        steps.reserveCapacity(file.steps.count)
        var previous = -1
        for entry in file.steps {
            guard entry.step > previous else {
                throw Unreadable(reason: "\(place) lists step \(entry.step) after step \(previous)")
            }
            previous = entry.step
            var inputs: [InputEvent] = []
            for raw in entry.inputs ?? [] {
                guard let event = raw.event else {
                    throw Unreadable(
                        reason: "\(place) has an input this mokume does not read at step \(entry.step) "
                            + "(type \(raw.type))")
                }
                inputs.append(event)
            }
            steps.append(
                Step(
                    step: entry.step, frame: entry.frame, drew: entry.drew, inputs: inputs,
                    params: entry.params ?? [], observeTime: entry.observe.map { Float($0.time) },
                    expose: (entry.expose ?? [:]).mapValues(\.value), pixelHash: entry.pixelHash))
        }
        return ReplayRecord(
            id: file.id, frameRate: file.clock.frameRate, width: file.size.width, height: file.size.height,
            window: file.window, startSeconds: file.start.seconds, startPaused: file.start.paused,
            startParams: file.start.params, steps: steps,
            unreproducible: (file.unreproducible ?? []).map(\.reason),
            last: file.last.map { ($0.frame, $0.pixelHash) })
    }

    // MARK: - 読む形

    /// 版と完成の印だけ。
    private struct Head: Decodable {
        let schemaVersion: Int?
        let complete: Bool?
    }

    private struct File: Decodable {
        struct Clock: Decodable {
            let kind: String
            let frameRate: Int
        }
        struct Size: Decodable {
            let width: Int
            let height: Int
        }
        struct Start: Decodable {
            let seconds: Double
            let paused: Bool
            let params: [NamedParamValue]
        }
        struct Observe: Decodable {
            let time: Double
        }
        /// `{"type", "value"}` の 1 つ。書き方は ``ExposedValue`` (= ``ParamValue``) のもの。
        struct Exposed: Decodable {
            let value: ParamValue
            init(from decoder: any Decoder) throws { value = try ParamValue(from: decoder) }
        }
        struct Entry: Decodable {
            let step: Int
            let frame: Int
            let drew: Bool
            let inputs: [RawInputEvent]?
            let params: [NamedParamValue]?
            let observe: Observe?
            let expose: [String: Exposed]?
            let pixelHash: String?
        }
        struct Note: Decodable {
            let reason: String
        }
        struct Last: Decodable {
            let frame: Int
            let pixelHash: String
        }
        let id: String
        let clock: Clock
        let size: Size
        let window: Bool
        let start: Start
        let steps: [Entry]
        let unreproducible: [Note]?
        let last: Last?
    }
}
