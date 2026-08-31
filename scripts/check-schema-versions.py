#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""面の仕様が破壊的に動いたとき、schemaVersion も上がっているかを見る (#637)。

`required` を足したのに `schemaVersion` の `const` を据え置くと、**同じ版を名乗る応答が
2 通りになる**。読み手は版から新旧を判定できず、形から推測するしかなくなる。

これは実際に起きた。`frames` (撮った絵の目録) を `required` で足したとき (#408)
`schemaVersion` は 1 のままだったため、版を固定した作品と新しい道具が繋がったときに、
絵が在るのに「絵は採れませんでした」と報告された (#635)。上げ方は ADR-0018 決定 5 が
表で定めているが、守っているのは書く人とレビューだけだった。

## 何を見るか

`origin/main` の同じファイルと手元の版を、**JSON ポインタをキーにした一般走査**で
突き合わせる。見るのは 3 つだけで、どれかがあれば「破壊的」と判定する:

  required に項目が増えた   古い書き手の応答が、新しい schema では検証を通らなくなる
  properties のキーが消えた  改名は「消えた + 増えた」として現れるので、消えた側で足りる
  type が変わった            同じ名前のまま、読み手の解釈が変わる

走査は `$defs` の中も `items` の中も辿るので、`frames.items.required` や
`$defs/stats.required` の追加も捕まる。

## 何を見ないか

**据え置きが正しい変更では黙る** — `description` の書き換え・`minimum` / `maximum` /
`enum` / `examples` の拡大・`required` に入らないキーの追加は、上の 3 つのどれにも
当たらない (ADR-0018 決定 5 の表で「据え置き」に落ちる行)。

**要求 (`*-request.schema.json`) は対象外。** 要求が版を持たないのは ADR-0018 決定 5 の
決定事項で、検査が求められるものが無い。対象外にしたことは出力が名乗る。

**「名前も型も同じまま意味が変わる」も見ない。** そこはスキーマに現れないので、人と
ADR が唯一の防壁である (ADR-0018 決定 5 の最後の行)。

## 比較の相手を引けないとき

解決は 3 段で、最後は**黙って 0 で返る** — 見ていないことを出力が名乗る:

  1. `--base` (既定 origin/main) が引けるならそれ
  2. 引けなければ `git fetch --depth=1 origin main` を試し FETCH_HEAD を使う
  3. それも駄目なら「見ていない」と名乗って 0

CI の浅い clone は段 2 で通る (remote は checkout が設定済み)。ネットワークの無い浅い
clone だけが段 3 に落ちる。ここで赤にしないのは、比較の材料が無いことは書いた人の
落ち度ではないからである。

呼び口は `bash scripts/check-schemas.sh` (make schemas が呼ぶ)。単体では
`python3 scripts/check-schema-versions.py --help`。
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

DEFAULT_BASE = "origin/main"
DEFAULT_SCHEMA_DIR = "Schemas"


def _git(args, cwd):
    """git を走らせ、成功した場合だけ標準出力を返す (失敗は None)。"""
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    return result.stdout if result.returncode == 0 else None


def resolve_base(base, cwd):
    """比較の相手を解決する。引けなければ None を返す (呼び手が名乗る)。"""
    if _git(["rev-parse", "--verify", "--quiet", f"{base}^{{commit}}"], cwd) is not None:
        return base
    # 浅い clone には origin/main が無い。比較のぶんだけ引く (履歴全体は要らない)
    if _git(["fetch", "--depth=1", "origin", "main"], cwd) is None:
        return None
    if _git(["rev-parse", "--verify", "--quiet", "FETCH_HEAD^{commit}"], cwd) is None:
        return None
    return "FETCH_HEAD"


def read_at(ref, path, cwd):
    """ref の時点での JSON を返す。その時点に無ければ None。"""
    body = _git(["show", f"{ref}:{path}"], cwd)
    if body is None:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def _pointer(key):
    """JSON ポインタのトークンとして鍵を綴る (RFC 6901)。"""
    return str(key).replace("~", "~0").replace("/", "~1")


def _types(value):
    """type を集合へ正規化する。読めない綴りは None。"""
    if isinstance(value, str):
        return frozenset([value])
    if isinstance(value, list):
        names = frozenset(v for v in value if isinstance(v, str))
        return names or None
    return None


def _collect(node, path, shape):
    if isinstance(node, dict):
        required = node.get("required")
        if isinstance(required, list):
            shape["required"][path] = frozenset(
                name for name in required if isinstance(name, str)
            )
        properties = node.get("properties")
        if isinstance(properties, dict):
            shape["properties"][path] = frozenset(properties)
        if "type" in node:
            types = _types(node["type"])
            if types is not None:
                shape["type"][path] = types
        for key, value in node.items():
            _collect(value, f"{path}/{_pointer(key)}", shape)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            _collect(value, f"{path}/{index}", shape)


def shape_of(document):
    """破壊的変化を見分けるのに要る形だけを、パスごとに拾う。"""
    shape = {"required": {}, "properties": {}, "type": {}}
    _collect(document, "", shape)
    return shape


def breaking_changes(before, after):
    """破壊的な変化を (何が, どこで, 何が) の並びで返す。据え置いてよい変更では空。"""
    found = []

    for path, names in sorted(after["required"].items()):
        was = before["required"].get(path)
        if was is None:
            continue  # そのノード自身が新しい。中の required は増えたのではない
        added = sorted(names - was)
        if added:
            found.append(("required に追加", path, added))

    for path, names in sorted(before["properties"].items()):
        now = after["properties"].get(path)
        if now is None:
            continue  # ノードごと消えた。親の properties から消えるのでそちらで捕まる
        gone = sorted(names - now)
        if gone:
            found.append(("キーが消えた", path, gone))

    for path, was in sorted(before["type"].items()):
        now = after["type"].get(path)
        if now is None or now == was:
            continue
        found.append(
            ("型が変わった", path, [f"{'|'.join(sorted(was))} → {'|'.join(sorted(now))}"])
        )

    return found


def declared_version(document):
    """schemaVersion の const を返す。宣言していなければ None。"""
    if not isinstance(document, dict):
        return None
    properties = document.get("properties")
    if not isinstance(properties, dict):
        return None
    version = properties.get("schemaVersion")
    if not isinstance(version, dict):
        return None
    const = version.get("const")
    if isinstance(const, bool) or not isinstance(const, int):
        return None
    return const


def _repo_prefix(cwd):
    """cwd のリポジトリのルートからの相対を返す (ルートなら空文字)。

    git show に渡す経路はルートからの相対でなければならず、--schema-dir は cwd
    からの相対で受ける。cwd がルートでないときに両者がずれる。
    """
    prefix = _git(["rev-parse", "--show-prefix"], cwd)
    return prefix.strip() if prefix else ""


def check(schema_dir, base, cwd, out=sys.stdout, err=sys.stderr):
    """0 (通った / 見ていない) か 1 (据え置きが見つかった) を返す。"""
    root = Path(schema_dir)
    schemas = sorted((Path(cwd) / root).glob("*.schema.json"))
    if not schemas:
        print(f"スキーマが 1 つも見つからない: {root}/*.schema.json", file=err)
        print("  検査が成立していないので落とす (何も見ていない緑を作らない)", file=err)
        return 1

    ref = resolve_base(base, cwd)
    if ref is None:
        print(
            f"注意: 比較の相手 ({base}) を引けず、schemaVersion の据え置きは見ていない。",
            file=out,
        )
        print(
            "      履歴を持たない clone でネットワークも無いときにここへ落ちる (#637)。",
            file=out,
        )
        return 0

    print(f"版の据え置きを見る: 比較の相手は {ref}", file=out)
    prefix = _repo_prefix(cwd)
    status = 0

    for schema in schemas:
        name = schema.name
        after = json.loads(schema.read_text())
        version = declared_version(after)
        if version is None:
            # 要求は版を持たない (ADR-0018 決定 5)。求められるものが無い
            print(f"対象外: {name} — schemaVersion を持たない", file=out)
            continue

        before = read_at(ref, f"{prefix}{root.as_posix()}/{name}", cwd)
        if before is None:
            print(f"対象外: {name} — {ref} には無い (新しい面)", file=out)
            continue

        changes = breaking_changes(shape_of(before), shape_of(after))
        if not changes:
            print(f"ok: {name} — 破壊的な変化なし (版は {version})", file=out)
            continue

        was = declared_version(before)
        if was is None or version > was:
            print(f"ok: {name} — 破壊的な変化に合わせて版が上がっている ({was} → {version})", file=out)
            continue

        status = 1
        print(
            f"{name}: 破壊的な変化があるのに schemaVersion が {version} のまま", file=err
        )
        for what, path, names in changes:
            print(f"  {what}  {path or '/'}  {', '.join(names)}", file=err)
        print(
            f"  properties.schemaVersion.const を {was + 1} へ上げる"
            " (据え置くと同じ版を名乗る応答が 2 通りになる — ADR-0018 決定 5 / #635)",
            file=err,
        )

    return status


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="面の仕様が破壊的に動いたとき、schemaVersion も上がっているかを見る (#637)",
        epilog="呼び口は bash scripts/check-schemas.sh (make schemas が呼ぶ)",
    )
    parser.add_argument(
        "--base",
        default=DEFAULT_BASE,
        help=f"比較の相手 (既定 {DEFAULT_BASE})。引けなければ浅く fetch し、それも駄目なら黙る",
    )
    parser.add_argument(
        "--schema-dir",
        default=DEFAULT_SCHEMA_DIR,
        help=f"スキーマの置き場 (既定 {DEFAULT_SCHEMA_DIR})",
    )
    args = parser.parse_args(argv)
    return check(args.schema_dir, args.base, cwd=Path.cwd())


if __name__ == "__main__":
    sys.exit(main())
