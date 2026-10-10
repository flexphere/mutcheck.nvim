-- mutcheck の JSON（-format json -v）から、ファイル・行ごとの hint を組み立てる。
-- Neovim の API に触らない純粋な処理だけを置く（テストから直接呼べるように）。

local M = {}

-- 行に hint を出すノードの種類。seq / alt / loop は位置を持たないか、構造だけのノードなので出さない
local positioned = { call = true, write = true }

-- "path:line" を絶対パスと行（1 始まり）に分ける。JSON の pos は -dir からの相対パス
local function split_pos(pos, root)
  local path, line = pos:match("^(.*):(%d+)$")
  if not path then
    return nil
  end
  if path:sub(1, 1) ~= "/" then
    path = root .. "/" .. path
  end
  return path, tonumber(line)
end

local function add(index, path, line, item)
  index[path] = index[path] or {}
  index[path][line] = index[path][line] or {}
  table.insert(index[path][line], item)
end

-- 記号名の #2 などはトランザクションの中で同名の記号を区別するためのもので、
-- トランザクションをまたいで式を比べるときは同じ式が別の値に見えてしまうので外す
local function plain(expr)
  return (expr:gsub("#%d+", ""))
end

-- tree を辿り、トランザクション内の呼び出し行に小計を積む。kind は commit 分なら "call"、DML 1 文分なら "dml"。
-- 1 行に入れ子の呼び出しが並ぶ（BufferWrite(Parent.Insert(...)) など）ときは、外側のノードだけを採る
local function walk(node, root, base, kind, seen, index)
  if positioned[node.kind] and node.pos and node.pos ~= "" then
    local path, line = split_pos(node.pos, root)
    if path then
      local key = path .. ":" .. line
      if not seen[key] then
        seen[key] = true
        add(index, path, line, vim.tbl_extend("force", base, { kind = kind, total = plain(node.total) }))
      end
    end
  end
  for _, c in ipairs(node.children or {}) do
    walk(c, root, base, kind, seen, index)
  end
end

-- build は JSON を { [絶対パス] = { [行] = { item, ... } } } にする。item の kind は次のどれか。
--   tx: トランザクション境界（total, check_reason, dml）
--   caller: トランザクションを始める関数の呼び出し元（total）
--   call / dml: トランザクション内の呼び出し（total）
-- どの item にも、どのトランザクションのものかを示す tx（トランザクションの位置）・func_full（-func に渡す名前）と、
-- そのトランザクションの判定 verdict を入れる
function M.build(report, root)
  local index = {}
  for _, tx in ipairs(report.transactions or {}) do
    local base = { tx = tx.pos, func_full = tx.func_full, verdict = tx.verdict }
    local path, line = split_pos(tx.pos, root)
    if path then
      add(
        index,
        path,
        line,
        vim.tbl_extend("force", base, {
          kind = "tx",
          total = tx.commit.expr,
          check_reason = tx.check_reason,
          dml = #(tx.dml or {}),
        })
      )
    end
    for _, c in ipairs(tx.callers or {}) do
      local cpath, cline = split_pos(c.pos, root)
      if cpath then
        add(
          index,
          cpath,
          cline,
          vim.tbl_extend("force", base, {
            kind = "caller",
            total = plain(tx.commit.expr),
          })
        )
      end
    end
    if tx.tree then
      walk(tx.tree, root, base, "call", {}, index)
    end
    -- DML は 1 文ごとに上限があるので、文ごとに別の seen で辿る
    for _, st in ipairs(tx.dml or {}) do
      if st.tree then
        walk(st.tree, root, base, "dml", {}, index)
      end
    end
  end
  return index
end

local verdict_hl = {
  fixed = "MutcheckFixed",
  dynamic = "MutcheckDynamic",
  over = "MutcheckOver",
  check = "MutcheckCheck",
}

-- 1 行に複数のトランザクションが関わるときは、いちばん重い判定の glyph と色にする
local severity = { fixed = 1, dynamic = 2, check = 3, over = 4 }

local function worst(items)
  local w = items[1].verdict
  for _, it in ipairs(items) do
    if (severity[it.verdict] or 0) > (severity[w] or 0) then
      w = it.verdict
    end
  end
  return w
end

-- 異なる値を max_values 個まで並べる。values は出現順
local function join_values(values, prefix, max_values)
  local shown = {}
  for i = 1, math.min(#values, max_values) do
    shown[i] = prefix .. values[i]
  end
  local text = table.concat(shown, " | ")
  if #values > max_values then
    text = text .. " | 他 " .. (#values - max_values) .. " 通り"
  end
  return text
end

-- items の異なる total と、トランザクションの数を数える
local function distinct(items)
  local values, seen, txs, count = {}, {}, {}, 0
  for _, it in ipairs(items) do
    if not seen[it.total] then
      seen[it.total] = true
      table.insert(values, it.total)
    end
    if not txs[it.tx] then
      txs[it.tx] = true
      count = count + 1
    end
  end
  return values, count
end

-- 1 行ぶんの item を virt_text（{ { text, hl }, ... }）にする。
-- どの値にも、そのトランザクションの判定の glyph（glyphs[verdict]）を先頭に付け、判定ごとのハイライトにする。
-- 複数のトランザクションから呼ばれる行は、トランザクションごとに小計が変わるので、異なる値を並べて件数を添える
function M.format(items, max_values, glyphs)
  glyphs = glyphs or {}
  local chunks = {}
  local function push(verdict, text)
    if #chunks > 0 then
      table.insert(chunks, { "  ", "MutcheckHint" })
    end
    local glyph = glyphs[verdict]
    if glyph and glyph ~= "" then
      text = glyph .. " " .. text
    end
    table.insert(chunks, { text, verdict_hl[verdict] or "MutcheckHint" })
  end

  local groups = { tx = {}, caller = {}, call = {}, dml = {} }
  for _, it in ipairs(items) do
    table.insert(groups[it.kind], it)
  end

  for _, it in ipairs(groups.tx) do
    local text = "commit " .. it.total
    if it.dml and it.dml > 0 then
      text = text .. " + DML " .. it.dml .. " 文"
    end
    text = text .. " · " .. it.verdict
    if it.check_reason and it.check_reason ~= "" then
      text = text .. "（" .. it.check_reason .. "）"
    end
    push(it.verdict, text)
  end

  -- 呼び出し先で始まるトランザクション。上限はコミットごとなので足し合わせず、コミット 1 回分を並べる
  if #groups.caller > 0 then
    local values, count = distinct(groups.caller)
    local head = count > 1 and ("tx×" .. count .. " ") or "tx "
    push(worst(groups.caller), head .. join_values(values, "", max_values))
  end

  for _, g in ipairs({ { groups.call, "+" }, { groups.dml, "DML " } }) do
    local calls, prefix = g[1], g[2]
    if #calls > 0 then
      local values, count = distinct(calls)
      local text = join_values(values, prefix, max_values)
      if count > 1 then
        text = text .. "（" .. count .. " tx）"
      end
      push(worst(calls), text)
    end
  end
  return chunks
end

-- targets は 1 行ぶんの item から、ツリーを表示するトランザクションの関数（func_full）を重複なく返す
function M.targets(items)
  local out, seen = {}, {}
  for _, it in ipairs(items or {}) do
    if it.func_full and not seen[it.func_full] then
      seen[it.func_full] = true
      table.insert(out, it.func_full)
    end
  end
  return out
end

-- func_pattern は関数の完全な名前の一覧を、-func に渡す正規表現（Go の RE2）にする
function M.func_pattern(names)
  local quoted = {}
  for i, n in ipairs(names) do
    quoted[i] = n:gsub("[%.%+%*%?%(%)%[%]%{%}%^%$|\\]", "\\%0")
  end
  return "^(?:" .. table.concat(quoted, "|") .. ")$"
end

return M
