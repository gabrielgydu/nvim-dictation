-- Extmark-backed range owned by dictation. Invariant: only mutate text that
-- dictation itself wrote. Every write verifies the range still contains
-- exactly last_written; any mismatch detaches permanently.
--
-- Gravity is chosen so *user* edits at the boundaries land outside the
-- range: start mark right_gravity=true (typing at the start pushes the range
-- right), end mark right_gravity=false (typing at the end stays after it).
-- Our own set_text scrambles marks with these gravities, so both marks are
-- re-pinned to known positions after each write.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('dictation.buffer')

local st = nil

function M.attach(buf, row, col)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, true)[1] or ''
  local prev = line:sub(1, col):sub(-1)
  st = {
    buf = buf,
    start_id = api.nvim_buf_set_extmark(buf, ns, row, col, { right_gravity = true }),
    end_id = api.nvim_buf_set_extmark(buf, ns, row, col, { right_gravity = false }),
    hl_id = nil,
    pad_before = prev ~= '' and not prev:match('%s'),
    last_written = '',
    wrote = false,
    detached = false,
    final_range = nil,
  }
end

local function marks()
  local s = api.nvim_buf_get_extmark_by_id(st.buf, ns, st.start_id, {})
  local e = api.nvim_buf_get_extmark_by_id(st.buf, ns, st.end_id, {})
  if #s == 0 or #e == 0 then
    return nil
  end
  if e[1] < s[1] or (e[1] == s[1] and e[2] < s[2]) then
    return nil
  end
  return s[1], s[2], e[1], e[2]
end

local function range_text(sr, sc, er, ec)
  local ok, lines = pcall(api.nvim_buf_get_text, st.buf, sr, sc, er, ec, {})
  if not ok then
    return nil
  end
  return table.concat(lines, '\n')
end

local function write(display, with_hl)
  if not st or st.detached then
    return false
  end
  if not api.nvim_buf_is_valid(st.buf) then
    st.detached = true
    return false
  end
  local sr, sc, er, ec = marks()
  if not sr then
    st.detached = true
    return false
  end
  local cur = range_text(sr, sc, er, ec)
  if cur == nil or cur ~= st.last_written then
    st.detached = true
    return false
  end

  if st.wrote then
    pcall(vim.cmd.undojoin) -- keep the interim stream out of undo history
  end
  local lines = vim.split(display, '\n', { plain = true })
  local ok = pcall(api.nvim_buf_set_text, st.buf, sr, sc, er, ec, lines)
  if not ok then
    st.detached = true
    return false
  end

  local ner = sr + #lines - 1
  local nec = #lines == 1 and sc + #lines[1] or #lines[#lines]

  api.nvim_buf_set_extmark(st.buf, ns, sr, sc, { id = st.start_id, right_gravity = true })
  api.nvim_buf_set_extmark(st.buf, ns, ner, nec, { id = st.end_id, right_gravity = false })

  if with_hl and display ~= '' then
    st.hl_id = api.nvim_buf_set_extmark(st.buf, ns, sr, sc, {
      id = st.hl_id,
      end_row = ner,
      end_col = nec,
      hl_group = 'DictationInterim',
    })
  elseif st.hl_id then
    api.nvim_buf_del_extmark(st.buf, ns, st.hl_id)
    st.hl_id = nil
  end

  st.last_written = display
  st.wrote = true
  return true, sr, sc, ner, nec
end

function M.write_interim(text)
  if not st then
    return false
  end
  local display = text == '' and '' or (st.pad_before and ' ' .. text or text)
  return write(display, true)
end

--- Returns ok, end_row, end_col where (end_row, end_col) is the position
--- just after the dictated text proper (before any trailing pad space).
function M.write_final(text)
  if not st then
    return false
  end
  local prefix = st.pad_before and ' ' or ''
  local suffix = ''
  local sr, sc, er, ec = marks()
  if sr then
    local line = api.nvim_buf_get_lines(st.buf, er, er + 1, false)[1]
    local nxt = line and line:sub(ec + 1, ec + 1) or ''
    if nxt ~= '' and not nxt:match('[%s%p]') then
      suffix = ' '
    end
  end
  local ok, wsr, wsc, ner, nec = write(prefix .. text .. suffix, false)
  if not ok then
    return false
  end
  st.final_range = { wsr, wsc, ner, nec }
  return true, ner, nec - #suffix
end

--- 0-based (row, col) inside or on the committed range?
function M.pos_in_range(row, col)
  local r = st and st.final_range
  if not r then
    return false
  end
  if row < r[1] or row > r[3] then
    return false
  end
  if row == r[1] and col < r[2] then
    return false
  end
  if row == r[3] and col > r[4] then
    return false
  end
  return true
end

function M.is_detached()
  return st ~= nil and st.detached
end

-- test/debug helper
function M.debug_range()
  if not st then
    return nil
  end
  return marks()
end

function M.remove()
  if st and not st.detached then
    write('', false)
  end
  M.cleanup()
end

function M.cleanup()
  if st and api.nvim_buf_is_valid(st.buf) then
    pcall(api.nvim_buf_del_extmark, st.buf, ns, st.start_id)
    pcall(api.nvim_buf_del_extmark, st.buf, ns, st.end_id)
    if st.hl_id then
      pcall(api.nvim_buf_del_extmark, st.buf, ns, st.hl_id)
    end
  end
  st = nil
end

return M
