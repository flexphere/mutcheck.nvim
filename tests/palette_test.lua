-- nvim --headless -l tests/palette_test.lua で実行する
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))
local palette = require("mutcheck.palette")
local commands = require("mutcheck.commands")

local failed = 0
local function eq(name, got, want)
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print("FAIL " .. name .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want))
  end
end

eq("<Cmd>", palette.rhs_invokes_command("<Cmd>MutcheckTree<CR>", "MutcheckTree"), true)
eq(":", palette.rhs_invokes_command(":MutcheckTree<CR>", "MutcheckTree"), true)
eq(":<C-u>", palette.rhs_invokes_command(":<C-u>MutcheckTree<CR>", "MutcheckTree"), true)
eq("小文字の <cmd>", palette.rhs_invokes_command("<cmd>MutcheckTree<cr>", "MutcheckTree"), true)
eq("名前の続きがある", palette.rhs_invokes_command("<Cmd>MutcheckTreeX<CR>", "MutcheckTree"), false)
eq("大文字小文字が違う", palette.rhs_invokes_command("<Cmd>mutchecktree<CR>", "MutcheckTree"), false)
eq(
  "先頭のコマンドではない",
  palette.rhs_invokes_command("<Cmd>update | MutcheckTree<CR>", "MutcheckTree"),
  false
)
eq("引数つき", palette.rhs_invokes_command("<Cmd>MutcheckTables Parent<CR>", "MutcheckTables"), true)

eq("<leader> に戻す", palette.format_key_lhs(" mt", " "), "<leader>mt")
eq("leader 未設定は \\", palette.format_key_lhs("\\mt", nil), "<leader>mt")

local keymaps = {
  { lhs = "<leader>mt", rhs = "<Cmd>MutcheckTree<CR>" },
  { lhs = "<leader>mx", callback = function() end },
}
eq("キーを見つける", palette.find_keymap_for_command(keymaps, "MutcheckTree"), "<leader>mt")
eq("callback のマッピングは見ない", palette.find_keymap_for_command(keymaps, "MutcheckRun"), nil)

local function names(entries)
  return vim.tbl_map(function(e)
    return e.name
  end, entries)
end
eq("hint のある行", names(palette.build_entries(commands.list, { project = {}, has_hint = true }, keymaps)), {
  "MutcheckTree",
  "MutcheckRun",
  "MutcheckTables",
  "MutcheckToggle",
})
eq(
  "hint のない行では Tree を出さない",
  names(palette.build_entries(commands.list, { project = {}, has_hint = false }, {})),
  {
    "MutcheckRun",
    "MutcheckTables",
    "MutcheckToggle",
  }
)
eq(
  "プロジェクトの外",
  names(palette.build_entries(commands.list, { has_hint = false }, {})),
  { "MutcheckToggle" }
)
eq(
  "キーを添える",
  palette.build_entries(commands.list, { project = {}, has_hint = true }, keymaps)[1].key,
  "<leader>mt"
)

local entries = palette.build_entries(commands.list, { project = {}, has_hint = true }, keymaps)
local widths = palette.calculate_widths(entries)
eq(
  "日本語の説明も表示幅でそろえる",
  vim.fn.strdisplaywidth(palette.format_entry(entries[2], widths)),
  widths.category + 2 + 2 + widths.desc + 2 + #":MutcheckRun"
)
eq("小さい端末では縮める", palette.calculate_layout(widths, 4, 20, 8), { width = 16, height = 4 })

if failed > 0 then
  print(failed .. " 件失敗")
  os.exit(1)
end
print("ok")
