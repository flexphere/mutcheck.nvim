-- nvim --headless -l tests/doc_test.lua で実行する
-- doc/mutcheck.txt のタグが重複せず、|リンク| がこのヘルプか Neovim のヘルプのタグを指していることを確かめる
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

local failed = 0
local function fail(msg)
  failed = failed + 1
  print("FAIL " .. msg)
end

-- リポジトリに doc/tags を作らないように、一時ディレクトリにコピーしてから :helptags を実行する
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/doc", "p")
local lines = vim.fn.readfile(root .. "/doc/mutcheck.txt")
vim.fn.writefile(lines, tmp .. "/doc/mutcheck.txt")
local ok, err = pcall(vim.cmd.helptags, tmp .. "/doc")
if not ok then
  fail(":helptags: " .. err)
end

local tags = {}
for _, line in ipairs(vim.fn.readfile(tmp .. "/doc/tags")) do
  tags[line:match("^[^\t]+")] = true
end
vim.fn.delete(tmp, "rf")

for i, line in ipairs(lines) do
  for ref in line:gmatch("|([^|%s]+)|") do
    if not tags[ref] and not vim.tbl_contains(vim.fn.getcompletion(ref, "help"), ref) then
      fail(("%d 行目: |%s| のタグがありません"):format(i, ref))
    end
  end
end

if failed > 0 then
  print(failed .. " 件失敗")
  os.exit(1)
end
print("ok")
