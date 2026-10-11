-- :checkhealth mutcheck。mutcheck を実行できるか、projects の設定どおりにファイルがあるかを確かめる

local M = {}

local health = vim.health

-- check_cmd は mutcheck の実行ファイルを探し、-version でバージョンを出す
local function check_cmd(cmd)
  if vim.fn.executable(cmd) ~= 1 then
    health.error("mutcheck が見つかりません: " .. cmd, {
      "go install github.com/flexphere/mutcheck@latest で入れます",
      "PATH にないときは cmd に実行ファイルのパスを指定します",
    })
    return
  end
  local path = vim.fn.exepath(cmd)
  local ok, res = pcall(function()
    return vim.system({ cmd, "-version" }, { text = true }):wait(5000)
  end)
  if not ok or res.code ~= 0 then
    health.warn("mutcheck のバージョンを取得できませんでした（" .. path .. "）", {
      "-version のない古い版かもしれません。go install github.com/flexphere/mutcheck@latest で入れ直します",
    })
    return
  end
  health.ok("mutcheck " .. vim.trim(res.stdout) .. "（" .. path .. "）")
end

-- check_project は解析するディレクトリが Go モジュールの中にあり、schema.sql が読めるかを確かめる
local function check_project(p)
  if vim.fn.isdirectory(p.root) ~= 1 then
    health.error("dir がありません: " .. p.root)
    return
  end
  local mod = vim.fs.root(p.root, "go.mod")
  if not mod then
    health.error("dir が Go モジュールの中にありません（go.mod が見つかりません）: " .. p.root)
  else
    health.ok("dir: " .. p.root .. "（go.mod: " .. mod .. "）")
  end
  for _, schema in ipairs(p.schema) do
    if vim.fn.filereadable(schema) == 1 then
      health.ok("schema: " .. schema)
    else
      health.error("schema を読めません: " .. schema)
    end
  end
end

-- check_picker は picker に指定したプラグインがあるかを確かめる。なければ vim.ui.select で開く
local function check_picker(picker)
  local modules = { telescope = "telescope.pickers", snacks = "snacks.picker" }
  local mod = modules[picker]
  if not mod then
    health.ok("picker: " .. tostring(picker))
    return
  end
  if pcall(require, mod) then
    health.ok("picker: " .. picker)
  else
    health.warn("picker の " .. picker .. " が見つからないので、vim.ui.select で開きます")
  end
end

function M.check()
  local state = require("mutcheck").health()

  health.start("mutcheck.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 以上が必要です（vim.system を使います）")
  end
  if not state.configured then
    health.warn(
      "setup() が呼ばれていません",
      { 'require("mutcheck").setup({ projects = { ... } }) を呼びます' }
    )
  end
  check_cmd(state.config.cmd)
  if vim.fn.executable("go") == 1 then
    health.ok("go: " .. vim.fn.exepath("go"))
  else
    health.error("go が見つかりません（mutcheck は go env / go list を実行します）")
  end
  check_picker(state.config.picker)

  health.start("mutcheck.nvim: projects")
  if #state.projects == 0 then
    health.warn("projects が空なので、どのファイルにも hint を出しません")
  end
  for _, p in ipairs(state.projects) do
    check_project(p)
  end
end

return M
