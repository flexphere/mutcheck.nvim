-- コマンドの登録簿。:MutcheckXxx の登録（register_all）と、:MutcheckCommandPalette の一覧（palette.lua）の
-- 両方がここから作るので、コマンドを足すときはここに足せば両方に出る。
--
-- 項目:
--   name      コマンド名
--   desc      1 行の説明（コマンドの desc とパレットの表示）
--   category  M.CATEGORIES のどれか（パレットでのまとまり）
--   available fun(ctx): boolean  パレットに出すか。ctx は require("mutcheck").context() の戻り値
--   run       fun(opts)  コマンドの本体（nvim_create_user_command の opts を受け取る）
--   nargs     引数をとるコマンドの nargs

local M = {}

-- パレットでのカテゴリの並び
M.CATEGORIES = { "Transaction", "Schema", "Display" }

local function in_project(ctx)
  return ctx.project ~= nil
end

M.list = {
  {
    name = "MutcheckTree",
    desc = "この行のトランザクションの内訳を表示する",
    category = "Transaction",
    available = function(ctx)
      return ctx.has_hint == true
    end,
    run = function()
      require("mutcheck").tree()
    end,
  },
  {
    name = "MutcheckRun",
    desc = "解析し直す",
    category = "Transaction",
    available = in_project,
    run = function()
      require("mutcheck").run_current()
    end,
  },
  {
    name = "MutcheckTables",
    desc = "テーブルごとの単価を表示する（-tables）",
    category = "Schema",
    available = in_project,
    nargs = "?",
    run = function(opts)
      require("mutcheck").tables(opts and opts.args)
    end,
  },
  {
    name = "MutcheckToggle",
    desc = "hint の表示を切り替える",
    category = "Display",
    available = function()
      return true
    end,
    run = function()
      require("mutcheck").toggle()
    end,
  },
}

function M.register_all()
  for _, cmd in ipairs(M.list) do
    vim.api.nvim_create_user_command(cmd.name, cmd.run, { desc = cmd.desc, nargs = cmd.nargs })
  end
end

return M
