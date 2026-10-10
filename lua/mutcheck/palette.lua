-- :MutcheckCommandPalette のコマンドパレット。fude.nvim の palette.lua と同じ作り。
-- commands.lua のコマンドのうち今使えるものを、説明とコマンド名で検索できるように並べ、
-- ユーザーがそのコマンドにキーを割り当てていればキーも出す。picker は config の picker（telescope / snacks / select）に従う。

local commands = require("mutcheck.commands")

local M = {}

----------------------------------------------------------------
-- 副作用のない処理
----------------------------------------------------------------

-- rhs_invokes_command は、マッピングの rhs が最初の Ex コマンドとして name を実行するか。
-- <Cmd>Name<CR> / :Name<CR> / :<C-u>Name<CR> を受け付ける。コマンド名は大文字小文字を区別する
function M.rhs_invokes_command(rhs, name)
  if name == "" then
    return false
  end
  local lower = rhs:lower()
  local pos = 1
  local function skip(pattern)
    local next_pos = lower:match("^" .. pattern .. "()", pos)
    if next_pos then
      pos = next_pos
    end
  end
  skip("<esc>")
  local after_wrapper = lower:match("^<cmd>()", pos) or lower:match("^:()", pos)
  if not after_wrapper then
    return false
  end
  pos = after_wrapper
  skip("<c%-u>")
  skip("%s*")
  if rhs:sub(pos, pos + #name - 1) ~= name then
    return false
  end
  -- MutcheckTree が MutcheckTreeX に当たらないように、名前の直後が識別子の文字でないことを見る
  return not rhs:sub(pos + #name, pos + #name):match("[%w_]")
end

-- find_keymap_for_command は、name を実行する最初のマッピングの lhs を返す。Lua の callback のマッピングは rhs がないので見ない
function M.find_keymap_for_command(keymaps, name)
  for _, km in ipairs(keymaps) do
    if type(km.rhs) == "string" and km.rhs ~= "" and M.rhs_invokes_command(km.rhs, name) then
      return km.lhs
    end
  end
  return nil
end

-- build_entries は、今使えるコマンドをカテゴリ順・登録順に並べ、キーを添える
function M.build_entries(cmds, ctx, keymaps, category_order)
  local order = {}
  for i, c in ipairs(category_order or commands.CATEGORIES) do
    order[c] = i
  end
  local entries = {}
  for i, cmd in ipairs(cmds) do
    if cmd.available(ctx) then
      table.insert(entries, {
        name = cmd.name,
        desc = cmd.desc,
        category = cmd.category,
        key = M.find_keymap_for_command(keymaps, cmd.name),
        index = i,
      })
    end
  end
  table.sort(entries, function(a, b)
    local ca, cb = order[a.category] or math.huge, order[b.category] or math.huge
    if ca ~= cb then
      return ca < cb
    end
    return a.index < b.index
  end)
  return entries
end

-- 説明に日本語があるので、幅は表示幅で数える
local function width(text)
  return vim.fn.strdisplaywidth(text)
end

local function pad(text, w)
  local cur = width(text)
  if cur >= w then
    return text
  end
  return text .. string.rep(" ", w - cur)
end

function M.calculate_widths(entries)
  local widths = { category = 0, desc = 0, name = 0, key = 0 }
  for _, e in ipairs(entries) do
    widths.category = math.max(widths.category, width(e.category))
    widths.desc = math.max(widths.desc, width(e.desc))
    widths.name = math.max(widths.name, width(e.name) + 1) -- 先頭の ":"
    if e.key then
      widths.key = math.max(widths.key, width(e.key))
    end
  end
  return widths
end

-- calculate_layout は、いちばん長い行と件数に合わせた picker の大きさ（40x6 以上、エディタより 4 小さい以下）
function M.calculate_layout(widths, count, columns, lines)
  local row = (widths.category + 2) + 2 + widths.desc + 2 + widths.name
  if widths.key > 0 then
    row = row + 2 + widths.key
  end
  local w = math.min(math.max(row + 6, 40), math.max(columns - 4, 1))
  local h = math.min(count + 5, math.max(lines - 4, 1))
  return { width = w, height = h }
end

-- format_key_lhs は nvim_get_keymap が展開した leader を <leader> に戻す
function M.format_key_lhs(lhs, mapleader)
  local leader = (mapleader == nil or mapleader == "") and "\\" or mapleader
  if lhs:sub(1, #leader) == leader then
    return "<leader>" .. lhs:sub(#leader + 1)
  end
  return lhs
end

-- format_entry は 1 件を「[Category]  説明  :Name  key」にする
function M.format_entry(e, widths)
  local line = pad("[" .. e.category .. "]", widths.category + 2) .. "  " .. pad(e.desc, widths.desc) .. "  "
  if e.key then
    return line .. pad(":" .. e.name, widths.name) .. "  " .. e.key
  end
  return line .. ":" .. e.name
end

----------------------------------------------------------------
-- 副作用のある処理
----------------------------------------------------------------

-- collect_keymaps は normal mode のバッファローカルとグローバルのマッピングを集める。
-- バッファローカルに同じ lhs があるグローバルのマッピングは、ここでは押しても動かないので除く
function M.collect_keymaps(buf)
  local list = {}
  local leader = vim.g.mapleader
  local local_lhs = {}
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    local_lhs[km.lhs] = true
    km.lhs = M.format_key_lhs(km.lhs, leader)
    table.insert(list, km)
  end
  for _, km in ipairs(vim.api.nvim_get_keymap("n")) do
    if not local_lhs[km.lhs] then
      km.lhs = M.format_key_lhs(km.lhs, leader)
      table.insert(list, km)
    end
  end
  return list
end

-- execute はパレットを開いたウィンドウに戻ってからコマンドを実行する（:MutcheckTree はカーソル行を使う）
function M.execute(entry, win)
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd({ cmd = entry.name })
end

function M.open(picker)
  local win = vim.api.nvim_get_current_win()
  local ctx = require("mutcheck").context()
  local entries = M.build_entries(commands.list, ctx, M.collect_keymaps(vim.api.nvim_get_current_buf()))
  if #entries == 0 then
    vim.notify("mutcheck: 使えるコマンドがありません", vim.log.levels.WARN)
    return
  end
  if picker == "telescope" then
    M.show_telescope(entries, win)
  elseif picker == "snacks" then
    M.show_snacks(entries, win)
  else
    M.show_select(entries, win)
  end
end

function M.show_telescope(entries, win)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.notify("mutcheck: telescope.nvim がないので vim.ui.select で開きます", vim.log.levels.WARN)
    M.show_select(entries, win)
    return
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local themes = require("telescope.themes")

  local widths = M.calculate_widths(entries)
  local layout = M.calculate_layout(widths, #entries, vim.o.columns, vim.o.lines)
  local displayer = entry_display.create({
    separator = "  ",
    items = {
      { width = widths.category + 2 },
      { width = widths.desc },
      { width = widths.name },
      { remaining = true },
    },
  })
  local function make_display(e)
    return displayer({
      { "[" .. e.category .. "]", "Title" },
      e.desc,
      { ":" .. e.name, "Comment" },
      { e.key or "", "Special" },
    })
  end
  for _, e in ipairs(entries) do
    e.display = make_display
    e.ordinal = e.desc .. " " .. e.name
  end

  pickers
    .new(themes.get_dropdown({ previewer = false, layout_config = { width = layout.width, height = layout.height } }), {
      prompt_title = "Mutcheck Command Palette",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          return e
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M.execute(selection, win)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.show_snacks(entries, win)
  local ok, snacks_picker = pcall(require, "snacks.picker")
  if not ok then
    vim.notify("mutcheck: snacks.nvim がないので vim.ui.select で開きます", vim.log.levels.WARN)
    M.show_select(entries, win)
    return
  end
  local widths = M.calculate_widths(entries)
  local layout = M.calculate_layout(widths, #entries, vim.o.columns, vim.o.lines)
  -- select の preset は結果の枠がないので、入力 1 行 + 区切り 1 行 + 件数
  local height = math.min(layout.height, #entries + 2)
  for _, e in ipairs(entries) do
    e.text = e.desc .. " " .. e.name
  end
  snacks_picker.pick({
    source = "mutcheck_palette",
    title = "Mutcheck Command Palette",
    items = entries,
    layout = {
      preset = "select",
      preview = false,
      layout = {
        width = layout.width,
        min_width = layout.width,
        max_width = layout.width,
        height = height,
        min_height = height,
        max_height = height,
      },
    },
    format = function(item)
      local chunks = {
        { pad("[" .. item.category .. "]", widths.category + 2) .. "  ", "Title" },
        { pad(item.desc, widths.desc) .. "  " },
        { pad(":" .. item.name, widths.name), "Comment" },
      }
      if item.key then
        table.insert(chunks, { "  " .. item.key, "Special" })
      end
      return chunks
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        M.execute(item, win)
      end
    end,
  })
end

function M.show_select(entries, win)
  local widths = M.calculate_widths(entries)
  vim.ui.select(entries, {
    prompt = "Mutcheck Command Palette:",
    format_item = function(e)
      return M.format_entry(e, widths)
    end,
  }, function(choice)
    if choice then
      M.execute(choice, win)
    end
  end)
end

return M
