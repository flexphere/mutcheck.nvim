-- mutcheck のテキスト出力を floating window に出す。
-- 色を付けたまま見られるように、出力は terminal buffer（nvim_open_term）に流す。

local M = {}

local function close(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

local function map_close(buf, win)
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close(win)
    end, { buffer = buf, nowait = true })
  end
end

-- open は cmd を実行し、終わったら出力を floating window に出す。実行中は「実行中…」を出しておく
function M.open(title, cmd)
  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.8)
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(placeholder, 0, -1, false, { "実行中…" })
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(placeholder, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  map_close(placeholder, win)

  local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      -- 結果が出る前に閉じられた
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      local out = res.stdout or ""
      if res.code ~= 0 then
        out = out .. (res.stderr or "") .. "\n終了コード " .. res.code .. "\n"
      end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.api.nvim_win_set_buf(win, buf)
      local chan = vim.api.nvim_open_term(buf, {})
      vim.api.nvim_chan_send(chan, (out:gsub("\r?\n", "\r\n")))
      map_close(buf, win)
      -- terminal への書き込みは非同期に反映されるので、少し待ってから先頭に戻す
      vim.defer_fn(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
      end, 50)
    end)
  end)
  if not ok then
    close(win)
    vim.notify("mutcheck: 実行できませんでした: " .. err, vim.log.levels.ERROR)
  end
end

return M
