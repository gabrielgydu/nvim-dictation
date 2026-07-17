-- Buffer ownership unit test. Runs headless (extmark logic needs no insert mode):
--   nvim --headless --clean --cmd "set rtp+=<repo>" -l test/unit_buffer.lua
local out = assert(io.open(os.getenv('TEST_RESULTS') or '/tmp/dictation_unit_buffer.txt', 'w'))
local failures = 0
local api = vim.api

local function check(name, cond, detail)
  out:write((cond and 'PASS  ' or 'FAIL  ') .. name .. (cond and '' or ('  -- ' .. vim.inspect(detail))) .. '\n')
  out:flush()
  if not cond then
    failures = failures + 1
  end
end

local function line()
  return api.nvim_buf_get_lines(0, 0, 1, true)[1]
end

local buffer = require('dictation.buffer')

-- 1) interim -> grow -> final, with leading pad
api.nvim_buf_set_lines(0, 0, -1, false, { 'hi' })
buffer.attach(0, 0, 2)
check('interim write with pad_before', buffer.write_interim('hello') and line() == 'hi hello', line())
check('interim replace grows', buffer.write_interim('hello world') and line() == 'hi hello world', line())

local ns = api.nvim_get_namespaces()['dictation.buffer']
local hl_found = false
for _, m in ipairs(api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
  if m[4] and m[4].hl_group == 'DictationInterim' then
    hl_found = true
  end
end
check('interim range is highlighted', hl_found)

local ok, erow, ecol = buffer.write_final('hello world')
check('final commit', ok and line() == 'hi hello world', line())
check('final end position after text', erow == 0 and ecol == 14, { erow, ecol })
check('interim highlight cleared on final', (function()
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    if m[4] and m[4].hl_group == 'DictationInterim' then
      return false
    end
  end
  return true
end)())
check('pos_in_range inside', buffer.pos_in_range(0, 5) and buffer.pos_in_range(0, 2) and buffer.pos_in_range(0, 14))
check('pos_in_range outside', not buffer.pos_in_range(0, 1) and not buffer.pos_in_range(1, 0))
buffer.cleanup()

-- 2) user edit inside the range detaches; user text is never clobbered
api.nvim_buf_set_lines(0, 0, -1, false, { 'ab' })
buffer.attach(0, 0, 2)
buffer.write_interim('xyz') -- 'ab xyz'
api.nvim_buf_set_text(0, 0, 4, 0, 5, { 'Q' }) -- user edit inside owned range
local w = buffer.write_interim('xyzw')
check('inside edit blocks further writes', w == false and buffer.is_detached(), { w = w, detached = buffer.is_detached() })
check('user edit preserved', line() == 'ab xQz', line())
check('final refused after detach', buffer.write_final('xyzw') == false)
buffer.cleanup()

-- 3) user edit outside the range shifts marks, ownership intact
api.nvim_buf_set_lines(0, 0, -1, false, { 'cd' })
buffer.attach(0, 0, 2)
buffer.write_interim('foo') -- 'cd foo'
api.nvim_buf_set_text(0, 0, 0, 0, 0, { 'Z' }) -- edit before the range
local ok3 = buffer.write_final('foo bar')
check('outside edit still commits', ok3 and line() == 'Zcd foo bar', line())
buffer.cleanup()

-- 4) trailing pad when a word character follows
api.nvim_buf_set_lines(0, 0, -1, false, { 'hiho' })
buffer.attach(0, 0, 2)
local ok4, er4, ec4 = buffer.write_final('X')
check('pads both sides between words', ok4 and line() == 'hi X ho', line())
check('end position excludes trailing pad', er4 == 0 and ec4 == 4, { er4, ec4 })
buffer.cleanup()

-- 5) no pads at line start / before punctuation
api.nvim_buf_set_lines(0, 0, -1, false, { '.' })
buffer.attach(0, 0, 0)
local ok5 = buffer.write_final('end')
check('no pad at line start or before punctuation', ok5 and line() == 'end.', line())
buffer.cleanup()

-- 6) remove() rolls interim back
api.nvim_buf_set_lines(0, 0, -1, false, { 'k' })
buffer.attach(0, 0, 1)
buffer.write_interim('gone')
buffer.remove()
check('remove rolls back interim', line() == 'k', line())
check('cleanup leaves no extmarks', #api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0)

-- 7) empty interim is a no-op-ish write
api.nvim_buf_set_lines(0, 0, -1, false, { 'm' })
buffer.attach(0, 0, 1)
check('empty interim ok', buffer.write_interim('') ~= false and line() == 'm', line())
buffer.cleanup()

out:write((failures == 0 and 'ALL PASS' or (failures .. ' FAILURE(S)')) .. '\n')
out:close()
os.exit(failures == 0 and 0 or 1)
