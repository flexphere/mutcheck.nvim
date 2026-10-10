-- nvim --headless -l tests/hints_test.lua で実行する
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))
local hints = require("mutcheck.hints")

local failed = 0
local function eq(name, got, want)
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print("FAIL " .. name .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want))
  end
end

local function write(pos, total)
  return { kind = "write", label = "insert", pos = pos, unit = total, total = total }
end

local report = {
  transactions = {
    {
      func = "app.A",
      func_full = "example.com/app.A",
      pos = "app/app.go:15",
      verdict = "fixed",
      commit = { expr = "5" },
      callers = { { pos = "main.go:3", func = "main.main" } },
      -- 入れ子の呼び出しが同じ行に並ぶ
      tree = {
        kind = "call",
        label = "BufferWrite",
        pos = "app/app.go:17",
        total = "5",
        children = {
          {
            kind = "call",
            label = "Parent.Insert",
            pos = "app/app.go:17",
            total = "5",
            children = { write("model/model.go:16", "5") },
          },
        },
      },
    },
    {
      func = "app.B",
      func_full = "example.com/app.B",
      pos = "app/app.go:30",
      verdict = "check",
      check_reason = "書き込みが見つからない",
      commit = { expr = "0" },
      callers = { { pos = "main.go:3", func = "main.main" } },
    },
    {
      func = "app.C",
      func_full = "(*example.com/app.T).C",
      pos = "app/app.go:40",
      verdict = "dynamic",
      commit = { expr = "5·ps" },
      -- loop は pos を持たないので、中の呼び出しにだけ出す
      tree = {
        kind = "loop",
        sym = "ps",
        total = "5·ps",
        children = {
          {
            kind = "call",
            label = "Parent.Insert",
            pos = "app/app.go:42",
            total = "5",
            children = { write("model/model.go:16", "5") },
          },
        },
      },
    },
    {
      func = "app.D",
      func_full = "example.com/app.D",
      pos = "app/app.go:50",
      verdict = "dynamic",
      commit = { expr = "0" },
      dml = {
        {
          op = "DML DELETE",
          table = "Parent",
          pos = "app/app.go:52",
          cost = { expr = "2·rows(Parent)" },
          tree = write("app/app.go:52", "2·rows(Parent)"),
        },
      },
    },
  },
}

local index = hints.build(report, "/m")

eq("tx の行", index["/m/app/app.go"][15], {
  { kind = "tx", total = "5", verdict = "fixed", dml = 0, tx = "app/app.go:15", func_full = "example.com/app.A" },
})
eq("同じ行の入れ子は外側だけ", index["/m/app/app.go"][17], {
  { kind = "call", total = "5", tx = "app/app.go:15", func_full = "example.com/app.A", verdict = "fixed" },
})
eq("check の理由", index["/m/app/app.go"][30][1].check_reason, "書き込みが見つからない")
eq("loop の中の呼び出し", #index["/m/app/app.go"][42], 1)
eq("複数のトランザクションから呼ばれる書き込み", #index["/m/model/model.go"][16], 2)
eq("DML の文", hints.format(index["/m/app/app.go"][52], 2), {
  { "DML 2·rows(Parent)", "MutcheckDynamic" },
})
eq("DML のあるトランザクション", hints.format(index["/m/app/app.go"][50], 2), {
  { "commit 0 + DML 1 文 · dynamic", "MutcheckDynamic" },
})

eq("tx の表示", hints.format(index["/m/app/app.go"][15], 2), {
  { "commit 5 · fixed", "MutcheckFixed" },
})
eq("check の表示", hints.format(index["/m/app/app.go"][30], 2), {
  { "commit 0 · check（書き込みが見つからない）", "MutcheckCheck" },
})
eq(
  "同じ値は 1 つにまとめて件数を添え、いちばん重い判定の色にする",
  hints.format(index["/m/model/model.go"][16], 2),
  {
    { "+5（2 tx）", "MutcheckDynamic" },
  }
)
eq("呼び出し元は件数と、いちばん重い判定の色", hints.format(index["/m/main.go"][3], 2), {
  { "tx×2 5 | 0", "MutcheckCheck" },
})
eq(
  "呼び出し元が 1 件",
  hints.format({
    { kind = "caller", total = "9·n", verdict = "dynamic", tx = "a" },
  }, 2),
  {
    { "tx 9·n", "MutcheckDynamic" },
  }
)
eq(
  "値が多いときは省略する",
  hints.format({
    { kind = "call", total = "5", tx = "a", verdict = "fixed" },
    { kind = "call", total = "9·n", tx = "b", verdict = "dynamic" },
    { kind = "call", total = "3", tx = "c", verdict = "fixed" },
  }, 2),
  {
    { "+5 | +9·n | 他 1 通り（3 tx）", "MutcheckDynamic" },
  }
)
eq(
  "同じ関数の 2 つのトランザクションは別に数える",
  hints.format({
    { kind = "call", total = "5", tx = "a.go:1", func_full = "f", verdict = "fixed" },
    { kind = "call", total = "5", tx = "a.go:9", func_full = "f", verdict = "fixed" },
  }, 2),
  {
    { "+5（2 tx）", "MutcheckFixed" },
  }
)
eq(
  "tx と呼び出しが同じ行",
  hints.format({
    { kind = "tx", total = "5", verdict = "fixed", tx = "a" },
    { kind = "call", total = "5", tx = "a", verdict = "fixed" },
  }, 2),
  {
    { "commit 5 · fixed", "MutcheckFixed" },
    { "  ", "MutcheckHint" },
    { "+5", "MutcheckFixed" },
  }
)
eq(
  "記号名の #N は外してまとめる",
  hints.format(
    hints.build({
      transactions = {
        {
          func = "a",
          pos = "x.go:1",
          verdict = "dynamic",
          commit = { expr = "n" },
          tree = { kind = "call", pos = "r.go:9", total = "10·n" },
        },
        {
          func = "b",
          pos = "y.go:1",
          verdict = "dynamic",
          commit = { expr = "n#2" },
          tree = { kind = "call", pos = "r.go:9", total = "10·n#2" },
        },
      },
    }, "/m")["/m/r.go"][9],
    2
  ),
  {
    { "+10·n（2 tx）", "MutcheckDynamic" },
  }
)
local glyphs = { fixed = "F", dynamic = "D", check = "C", over = "O" }
eq(
  "判定の glyph を値ごとに付ける",
  hints.format({
    { kind = "tx", total = "90000", verdict = "over", tx = "a" },
    { kind = "call", total = "5", tx = "a", verdict = "over" },
  }, 2, glyphs),
  {
    { "O commit 90000 · over", "MutcheckOver" },
    { "  ", "MutcheckHint" },
    { "O +5", "MutcheckOver" },
  }
)
eq("呼び出し元の glyph はいちばん重い判定", hints.format(index["/m/main.go"][3], 2, glyphs), {
  { "C tx×2 5 | 0", "MutcheckCheck" },
})
eq("空の glyph は付けない", hints.format(index["/m/app/app.go"][15], 2, { fixed = "" }), {
  { "commit 5 · fixed", "MutcheckFixed" },
})
eq(
  "絶対パスの pos はそのまま",
  hints.build(
    { transactions = {
      { func = "x", pos = "/abs/x.go:3", verdict = "fixed", commit = { expr = "1" } },
    } },
    "/m"
  )["/abs/x.go"][3][1].total,
  "1"
)

eq("ツリーの対象は関数ごとに 1 つ", hints.targets(index["/m/main.go"][3]), {
  "example.com/app.A",
  "example.com/app.B",
})
eq(
  "-func の正規表現",
  hints.func_pattern({ "(*example.com/app.T).C$1", "example.com/app.A" }),
  "^(?:\\(\\*example\\.com/app\\.T\\)\\.C\\$1|example\\.com/app\\.A)$"
)

if failed > 0 then
  print(failed .. " 件失敗")
  os.exit(1)
end
print("ok")
