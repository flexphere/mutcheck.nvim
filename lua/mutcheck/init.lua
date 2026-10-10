-- mutcheck.nvim: 保存のたびに mutcheck を実行し、トランザクション境界と
-- トランザクション内の呼び出し行に mutation 数を virtual text で出す。

local hints = require("mutcheck.hints")
local float = require("mutcheck.float")

local M = {}

local config = {
  -- mutcheck の実行ファイル
  cmd = "mutcheck",
  -- 解析するモジュールごとの設定。{ dir = モジュールのディレクトリ, schema = schema.sql のパス（複数なら table）, args = 追加の引数 }
  projects = {},
  -- 複数のトランザクションから呼ばれる行で、並べる小計の数
  max_values = 2,
  -- virtual text の先頭に付ける文字列
  prefix = "muts: ",
  -- コマンドパレットの picker: "telescope" / "snacks" / "select"（vim.ui.select）
  picker = "select",
  -- 判定ごとに値の先頭に付ける glyph。空文字なら付けない
  glyphs = {
    fixed = "✓",
    dynamic = "~",
    check = "!",
    over = "✗",
  },
}

local ns = vim.api.nvim_create_namespace("mutcheck")
local enabled = true
local projects = {}

local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function project_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local path = realpath(name)
  for _, p in ipairs(projects) do
    if vim.startswith(path, p.root .. "/") then
      return p, path
    end
  end
  return nil
end

local function render(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local p, path = project_of(buf)
  if not enabled or not p or not p.index or p.stale then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for line, items in pairs(p.index[path] or {}) do
    -- 保存後に行が減っていても、次の解析結果までは範囲外の hint を出さない
    if line <= count then
      local chunks = hints.format(items, config.max_values, config.glyphs)
      chunks[1][1] = config.prefix .. chunks[1][1]
      -- 解析中は、いま出ているのが前回の結果だと分かるように薄くする
      if p.job then
        for _, c in ipairs(chunks) do
          c[2] = "MutcheckStale"
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
        virt_text = chunks,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

local function render_project(p)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if project_of(buf) == p then
      render(buf)
    end
  end
end

local function has_buffer(p)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and project_of(buf) == p then
      return true
    end
  end
  return false
end

-- 表示を戻す。消している間は保存しても解析していないので、前の結果は行がずれているかもしれない。
-- ファイルを開いているプロジェクトを解析し直し、結果が出るまでは出さない
local function enable()
  enabled = true
  for _, p in ipairs(projects) do
    if has_buffer(p) then
      p.stale = true
      M.run(p)
    end
  end
end

local function error_packages(report)
  local set = {}
  for _, e in ipairs(report.load_errors or {}) do
    set[e.package] = true
  end
  return set
end

-- 型エラーのあるパッケージのトランザクションは結果に入らず、そこにある実装も読めなくなる。
-- 前回の解析から型エラーのパッケージが増えたら（編集途中の保存など）、少なく出た値で上書きせず前回の結果を残す。
-- もとからあるエラーだけなら、そのまま新しい結果を使う
local function new_errors(p, report)
  local cur = error_packages(report)
  local added = {}
  for pkg in pairs(cur) do
    if not (p.error_packages or {})[pkg] then
      table.insert(added, pkg)
    end
  end
  table.sort(added)
  return cur, added
end

-- 前回の結果は、nvim を開き直したときにすぐ出せるようにプロジェクトごとに保存しておく
local function cache_path(p)
  return vim.fn.stdpath("cache") .. "/mutcheck/" .. vim.fn.sha256(p.root) .. ".json"
end

local function save_cache(p, stdout)
  local path = cache_path(p)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = io.open(path, "w")
  if f then
    f:write(stdout)
    f:close()
  end
end

-- load_cache は保存しておいた前回の結果を読む。読めなければ何もしない（解析の結果を待つ）
local function load_cache(p)
  if p.index then
    return
  end
  local f = io.open(cache_path(p), "r")
  if not f then
    return
  end
  local data = f:read("*a")
  f:close()
  local ok, report = pcall(vim.json.decode, data)
  if not ok then
    return
  end
  local built, index = pcall(hints.build, report, p.root)
  if built then
    p.index = index
    p.error_packages = error_packages(report)
  end
end

local function apply(p, res)
  if res.code ~= 0 then
    render_project(p)
    vim.notify("mutcheck: 終了コード " .. res.code .. "\n" .. (res.stderr or ""), vim.log.levels.ERROR)
    return
  end
  local ok, report = pcall(vim.json.decode, res.stdout)
  if not ok then
    render_project(p)
    vim.notify("mutcheck: JSON を読めませんでした: " .. report, vim.log.levels.ERROR)
    return
  end
  local cur, added = new_errors(p, report)
  if p.index and #added > 0 then
    render_project(p)
    vim.notify(
      "mutcheck: 型エラーのため前回の結果を表示しています（" .. table.concat(added, ", ") .. "）",
      vim.log.levels.WARN
    )
    return
  end
  p.error_packages = cur
  p.index = hints.build(report, p.root)
  render_project(p)
  save_cache(p, res.stdout)
end

local function on_done(p, res)
  p.job = nil
  -- 実行し直した結果が出たら、失敗や型エラーで前回の結果を使う場合も含めて表示を戻す
  p.stale = false
  apply(p, res)
  -- 解析中に保存されていたら、最新の内容でもう一度だけ解析する
  if p.pending then
    p.pending = false
    M.run(p)
  end
end

function M.run(p)
  -- 解析中は止めずに最後まで待つ（止めてやり直すと、続けて保存している間は結果が一度も出ない）。
  -- 終わったら、最新の内容でもう一度だけ解析する
  if p.job then
    p.pending = true
    return
  end
  local cmd = { config.cmd, "-v", "-format", "json", "-schema", table.concat(p.schema, ","), "-dir", p.root }
  vim.list_extend(cmd, p.args or {})
  local ok, job = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      on_done(p, res)
    end)
  end)
  if not ok then
    vim.notify("mutcheck: 実行できませんでした: " .. job, vim.log.levels.ERROR)
    return
  end
  p.job = job
  render_project(p)
end

local function short_func(full)
  -- (*example.com/app.T).m → app.T.m
  return (full:gsub("[%(%)%*]", ""):gsub("^.*/", ""))
end

-- tree は今の行の hint のもとになったトランザクションを、-func で指定して実行したときの出力（内訳つき）を出す
function M.tree()
  local p, path = project_of(0)
  if not p then
    vim.notify("mutcheck: このバッファは projects のどれにも含まれていません", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local names = hints.targets(p.index and p.index[path] and p.index[path][line])
  if #names == 0 then
    vim.notify("mutcheck: この行には hint がありません", vim.log.levels.WARN)
    return
  end
  local cmd = {
    config.cmd,
    "-v",
    "-color",
    "always",
    "-schema",
    table.concat(p.schema, ","),
    "-dir",
    p.root,
    "-func",
    hints.func_pattern(names),
  }
  vim.list_extend(cmd, p.args or {})
  local title = #names <= 3 and table.concat(vim.tbl_map(short_func, names), ", ") or (#names .. " 関数")
  float.open("mutcheck -func " .. title, cmd)
end

-- tables は -tables の出力を出す。arg を省くと all
function M.tables(arg)
  local p = project_of(0) or (#projects == 1 and projects[1])
  if not p then
    vim.notify("mutcheck: このバッファは projects のどれにも含まれていません", vim.log.levels.WARN)
    return
  end
  local tables = (arg and arg ~= "") and arg or "all"
  float.open("mutcheck -tables " .. tables, {
    config.cmd,
    "-color",
    "always",
    "-schema",
    table.concat(p.schema, ","),
    "-tables",
    tables,
  })
end

-- run_current は今のバッファのプロジェクトを解析し直す
function M.run_current()
  local p = project_of(0)
  if not p then
    vim.notify("mutcheck: このバッファは projects のどれにも含まれていません", vim.log.levels.WARN)
    return
  end
  -- 表示を消している間に実行しても結果が見えないので、表示も戻す
  if not enabled then
    enable()
    return
  end
  M.run(p)
end

function M.toggle()
  if enabled then
    enabled = false
    for _, p in ipairs(projects) do
      render_project(p)
    end
  else
    enable()
  end
end

-- context はコマンドパレットに出すコマンドを決めるための、今のバッファとカーソル行の状態
function M.context()
  local p, path = project_of(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local items = p and p.index and p.index[path] and p.index[path][line]
  return { project = p, has_hint = enabled and items ~= nil and #items > 0 }
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  projects = {}
  for _, p in ipairs(config.projects) do
    -- mutcheck はシェルを通さずに起動するので、~ はここで展開する
    local schemas = type(p.schema) == "table" and p.schema or { p.schema }
    table.insert(projects, {
      root = realpath(vim.fn.expand(p.dir)),
      schema = vim.tbl_map(vim.fn.expand, schemas),
      args = p.args,
    })
  end

  -- 判定は glyph で見分けるので、色は MutcheckHint の 1 色にそろえ、固定は緑、超過は赤にする。
  -- MutcheckHint を変えれば件数次第・要確認の色がまとめて変わる
  for _, hl in ipairs({
    { "MutcheckHint", "Number" },
    { "MutcheckFixed", "DiagnosticOk" },
    { "MutcheckDynamic", "MutcheckHint" },
    { "MutcheckCheck", "MutcheckHint" },
    { "MutcheckOver", "DiagnosticError" },
    { "MutcheckStale", "Comment" },
  }) do
    vim.api.nvim_set_hl(0, hl[1], { link = hl[2], default = true })
  end

  local group = vim.api.nvim_create_augroup("mutcheck", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.go",
    callback = function(ev)
      local p = project_of(ev.buf)
      if not p or not enabled then
        return
      end
      -- 中身を変えずに :w しただけなら解析し直さない（changedtick は編集のたびに増える）
      local tick = vim.b[ev.buf].changedtick
      if vim.b[ev.buf].mutcheck_tick == tick then
        return
      end
      vim.b[ev.buf].mutcheck_tick = tick
      M.run(p)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "*.go",
    callback = function(ev)
      local p = project_of(ev.buf)
      if not p or not enabled then
        return
      end
      -- 開いた時点の中身は解析済み（または初回の解析に含まれる）として、変更のない保存を見分ける基準にする
      if vim.b[ev.buf].mutcheck_tick == nil then
        vim.b[ev.buf].mutcheck_tick = vim.b[ev.buf].changedtick
      end
      -- 初めて開いたときは、前回の結果をすぐ出しつつ、保存を待たずに一度解析する
      if not p.analyzed then
        p.analyzed = true
        load_cache(p)
        M.run(p)
      end
      render(ev.buf)
    end,
  })

  -- :MutcheckXxx は commands.lua の登録簿から作る（コマンドパレットと共通）
  require("mutcheck.commands").register_all()
  vim.api.nvim_create_user_command("MutcheckCommandPalette", function()
    require("mutcheck.palette").open(config.picker)
  end, { desc = "mutcheck のコマンドパレットを開く" })

  -- ft = "go" などで遅延読み込みされたときは、開いているバッファの BufWinEnter がもう過ぎている
  local p = project_of(0)
  if p and enabled and not p.analyzed then
    p.analyzed = true
    load_cache(p)
    M.run(p)
  end
end

return M
