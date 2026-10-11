# mutcheck.nvim

[mutcheck](https://github.com/flexphere/mutcheck) の解析結果を、Go のコードに virtual text で表示する Neovim プラグインです（PoC）。
Spanner の ReadWriteTransaction ごとの mutation 数を、トランザクション境界、トランザクション内の呼び出し行、トランザクションを始める関数の呼び出し元の行末に出します。

```go
c.ReadWriteTransaction(ctx, func(...) error {          muts: ~ commit 5·ps · dynamic
    for _, p := range ps {
        muts = append(muts, p.Insert(ctx))             muts: ~ +5
    }
    return tx.BufferWrite(muts)                        muts: ~ +5·ps
})
```

## 必要なもの

- Neovim 0.10 以上（`vim.system` を使います）
- `mutcheck`（`go install github.com/flexphere/mutcheck@latest`）

## 設定

```lua
-- lazy.nvim
{
  "flexphere/mutcheck.nvim",
  ft = "go",
  opts = {
    projects = {
      {
        -- 解析する Go モジュールのディレクトリ
        dir = "~/src/app",
        -- schema.sql のパス。DB が複数あれば table で渡す
        schema = "~/src/app/db/schema.sql",
        -- mutcheck に渡す追加の引数（任意）
        args = {},
      },
    },
    -- mutcheck の実行ファイル（任意）
    cmd = "mutcheck",
    -- 複数のトランザクションから呼ばれる行で、並べる小計の数（任意）
    max_values = 2,
    -- virtual text の先頭に付ける文字列（任意）
    prefix = "muts: ",
    -- コマンドパレットの picker: "telescope" / "snacks" / "select"（vim.ui.select。既定）
    picker = "select",
    -- 判定ごとに値の先頭に付ける glyph（任意）。空文字なら付けない
    glyphs = { fixed = "✓", dynamic = "~", check = "!", over = "✗" },
  },
}
```

`projects` の `dir` 以下の `*.go` だけが対象です。

## いつ更新されるか

- 対象のファイルを初めて開いたときに、一度解析します。前回の解析結果を `stdpath("cache")/mutcheck/` に残しているので、解析が終わるまではそれを表示します。
- 保存（`BufWritePost`）のたびに解析し直します。
  - 中身を変えずに `:w` しただけのときは解析しません。nvim の外でコードが変わったときは `:MutcheckRun` を使います。
- mutcheck は毎回モジュール全体を読み込むので、結果が出るまで時間がかかります（数百パッケージのモジュールで 1 秒前後）。それまでは前回の結果を薄い色（`MutcheckStale`）で表示し、結果が出たら元の色に戻します。
- 解析中に保存した場合は、今の解析を最後まで続けて結果を出し、そのあと最新の内容でもう一度だけ解析します（続けて保存しても、そのたびに最初からやり直すことはしません）。
- 保存前の編集内容は解析しません。

## 表示

どの値にも、そのトランザクションの判定（`fixed` / `dynamic` / `check` / `over`）の glyph を先頭に付けます（`glyphs` で変えられます）。
1 行に複数のトランザクションが関わるときは、いちばん重い判定（`over` > `check` > `dynamic` > `fixed`）の glyph にします。
色は 1 色にそろえ、固定（`fixed`）だけ緑、超過（`over`）だけ赤にします（ハイライトの節を参照）。

### トランザクション境界の行

```text
muts: ~ commit 6 + 9·orderIDs · dynamic
muts: ~ commit 0 + DML 1 文 · dynamic
```

- commit 1 回分の mutation 数の式と判定（`fixed` / `dynamic` / `over` / `check`）を出します。
- DML を実行していれば、その文の数を添えます。DML の mutation 数は、その文の行に出ます。

### トランザクション内の呼び出し行

```text
muts: ~ +9·userIDs
muts: ~ DML 1·rows(Child←Parent) + 2·rows(Parent)
muts: ~ +11 + 10·items（52 tx）
muts: ~ +5 | +9·n | 他 1 通り（3 tx）
```

- その呼び出し 1 回分の mutation 数を `+` 付きで出します。ループの中の呼び出しは、1 回分の値です。
- DML の文の中の呼び出しは `DML` を付けます。DML は文ごとに上限があるので、commit 分とは分けています。
- 1 行に入れ子の呼び出しが並ぶ場合（`BufferWrite(p.Insert(ctx))` など）は、外側の呼び出しの値だけを出します。
- 複数のトランザクションから呼ばれる行には、異なる値を `max_values` 個まで並べ、トランザクションの数を添えます。
  - 式の中の記号名の `#2` などは、トランザクションの中で同名の記号を区別するためのものなので、この行では外してまとめます。

### トランザクションを始める関数の呼び出し元

```text
muts: ~ tx 9·targets
muts: ~ tx×2 5 | 9·n
```

- 中でトランザクションを始める関数（`PlaceOrder` など）を呼んでいる行に、そのトランザクションの commit 1 回分の式を `tx` 付きで出します。
- 上限はコミットごとなので、複数のトランザクションを始める関数でも足し合わせず、`tx×N` で件数を添えて値を並べます。
- 直接の呼び出し元だけです（1 段）。式の記号は呼ばれる側での名前のままです。
- interface 経由の呼び出しは、メソッド名が同じで実装しうるものを拾うので、実際には別の実装が呼ばれる行にも出ることがあります。

## 型エラーがあるとき

型エラーのあるパッケージは mutcheck の結果に入らず、そこにある実装も読めなくなるので、mutation 数が少なく出ます。

- 前回の解析から型エラーのあるパッケージが増えた場合は、前回の結果を残し、警告を出します。
- もとから型エラーのあるパッケージだけであれば、新しい結果を表示します。

## コマンド

- `:MutcheckCommandPalette`: 今使えるコマンドの一覧を出し、選んで実行します。
  - `:MutcheckTree` は、カーソル行に hint があるときだけ出ます。ほかのコマンドは、バッファが `projects` のどれかに入っていれば出ます。
  - 説明とコマンド名で絞り込めます（telescope / snacks、または picker 付きの `vim.ui.select`）。
  - コマンドにキーを割り当てていれば、そのキーも出ます（`<Cmd>MutcheckTree<CR>` のような rhs のマッピングだけ）。

- `:MutcheckRun`: 今のバッファのプロジェクトを解析し直します。
  - `git checkout` や nvim の外での編集、schema.sql の変更など、保存を挟まずにコードが変わったときに使います。
  - 表示を消していた場合は、表示も戻します。
- `:MutcheckTree`: 今の行の hint のもとになったトランザクションの内訳を、floating window に出します。
  - mutcheck を `-v -func` で、その行に関わるトランザクションの関数を指定して実行したときと同じ出力です。
  - mutcheck を実行し直すので、結果が出るまでは「実行中…」を出します。
  - 関数で指定するので、同じ関数の中にほかのトランザクションがあれば、それも出ます。
- `:MutcheckTables [テーブル]`: `-tables` の出力（テーブルごとの単価）を floating window に出します。テーブルを省くと `all` です。
- floating window は `q` か `<Esc>` で閉じます。
- `:MutcheckToggle`: 表示を切り替えます。
  - 消している間は、保存しても解析しません。
  - 戻すときは、ファイルを開いているプロジェクトを解析し直し、結果が出てから表示します。

## ハイライト

- `MutcheckHint`（既定: `Number`）: hint の色。件数次第・要確認はこの色になります
- `MutcheckDynamic` / `MutcheckCheck`（既定: `MutcheckHint`）: 判定ごとに色を分けたいときに上書きします
- `MutcheckFixed`（既定: `DiagnosticOk`）: 固定
- `MutcheckOver`（既定: `DiagnosticError`）: 超過
- `MutcheckStale`（既定: `Comment`）: 解析中に表示している前回の結果

## 開発

[mise](https://mise.jdx.dev/) で Neovim・stylua・selene のバージョンをそろえています。

```sh
mise install       # mise.toml のツールを入れる
mise run format    # stylua で整形する
mise run lint      # 整形漏れ（stylua）と静的解析（selene）
mise run test      # tests/*_test.lua を headless の Neovim で実行する
mise run check     # lint と test
```

GitHub Actions では push と pull request のたびに `mise run check` を実行します（`.github/workflows/ci.yml`）。
workflow が使う action は [gh-actions-lock](https://github.com/github/gh-actions-lock) でコミットに固定しています（`.github/workflows/actions.lock`）。`uses` を追加・変更したときは lockfile を更新します。

```sh
gh extension install github/gh-actions-lock
gh actions-lock            # workflow を走査して lockfile を更新する
gh actions-lock --relock   # 固定しているバージョンを上流の最新コミットに上げる
```

コマンドを足すときは `lua/mutcheck/commands.lua` の登録簿に足します。`:MutcheckXxx` の登録とコマンドパレットの両方に出ます。

## ライセンス

MIT（`LICENSE`）
