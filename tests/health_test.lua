-- nvim --headless -l tests/health_test.lua で実行する
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local failed = 0
local function expect(name, cond, detail)
  if not cond then
    failed = failed + 1
    print("FAIL " .. name .. (detail and ("\n  " .. detail) or ""))
  end
end

-- vim.health の出力を { level, msg } で集める
local reports
local function capture(fn)
  reports = {}
  local saved = {}
  for _, level in ipairs({ "start", "ok", "warn", "error" }) do
    saved[level] = vim.health[level]
    vim.health[level] = function(msg)
      table.insert(reports, { level = level, msg = msg })
    end
  end
  local ok, err = pcall(fn)
  for level, f in pairs(saved) do
    vim.health[level] = f
  end
  assert(ok, err)
end

local function has(level, pattern)
  for _, r in ipairs(reports) do
    if r.level == level and r.msg:find(pattern) then
      return true
    end
  end
  return false
end

local function dump()
  return vim.inspect(reports)
end

local health = require("mutcheck.health")

-- setup 前は警告を出す
capture(health.check)
expect("setup 前", has("warn", "setup%(%) が呼ばれていません"), dump())

-- 実行ファイル・モジュール・schema がそろっている
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/app/sub", "p")
vim.fn.writefile({ "module example.com/app" }, tmp .. "/app/go.mod")
vim.fn.writefile({ "CREATE TABLE T (ID STRING(36)) PRIMARY KEY (ID);" }, tmp .. "/schema.sql")
local fake = tmp .. "/mutcheck"
vim.fn.writefile({ "#!/bin/sh", "echo v1.2.3" }, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")

require("mutcheck").setup({
  cmd = fake,
  projects = { { dir = tmp .. "/app/sub", schema = { tmp .. "/schema.sql" } } },
})
capture(health.check)
expect("setup 後は警告しない", not has("warn", "setup"), dump())
expect("バージョンを出す", has("ok", "mutcheck v1%.2%.3"), dump())
expect("モジュールの中のディレクトリ", has("ok", "go%.mod: "), dump())
expect("schema を読める", has("ok", "schema: "), dump())

-- 古い版（-version がない）、モジュールの外、schema がない、実行ファイルがない
vim.fn.writefile({ "#!/bin/sh", "exit 2" }, fake)
vim.fn.mkdir(tmp .. "/nomod", "p")
require("mutcheck").setup({
  cmd = fake,
  projects = { { dir = tmp .. "/nomod", schema = tmp .. "/missing.sql" } },
})
capture(health.check)
expect("バージョンが取れない", has("warn", "バージョンを取得できませんでした"), dump())
expect("go.mod がない", has("error", "Go モジュールの中にありません"), dump())
expect("schema がない", has("error", "schema を読めません"), dump())

require("mutcheck").setup({ cmd = tmp .. "/none", projects = {} })
capture(health.check)
expect("実行ファイルがない", has("error", "mutcheck が見つかりません"), dump())
expect("projects が空", has("warn", "projects が空"), dump())

vim.fn.delete(tmp, "rf")

if failed > 0 then
  print(failed .. " 件失敗")
  os.exit(1)
end
print("ok")
