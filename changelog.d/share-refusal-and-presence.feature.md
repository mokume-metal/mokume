<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

別のアプリへ絵を渡したくない作品は、`SketchSettings` の `sharesFrames` を `false` にすると、どの起こし方でも一覧に出ず、繋ぐための名前も登録しなくなりました (既定は `true`)。カメラ・マイク・守られた場所のファイルなど、画面収録の許可の外で守られたものを描く作品は、断ることを考えてください。絵を渡している間は、起動から 30 秒の猶予を待たずにメニューバーへ名乗り、メニューに渡している相手 (`Frames to …`) が出ます。繋がった・切れたことは 1 行ずつ知らせます。`mokume watch` では道具が端末に 1 行ずつ言い、プレビューのウィンドウの題に相手を添えます。

```swift
var settings: SketchSettings {
    var settings = SketchSettings.size(640, 360)
    settings.sharesFrames = false
    return settings
}
```
