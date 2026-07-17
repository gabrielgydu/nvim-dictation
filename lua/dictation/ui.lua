local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('dictation.ui')

local hint -- { buf, id }
local rec -- { buf, row, id }

local LEVELS = { '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' }

function M.setup(_config) end

-- hint fns are called from the expr-mapping context, so they schedule
function M.show_hint()
  vim.schedule(function()
    if hint then
      return
    end
    local buf = api.nvim_get_current_buf()
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local ok, id = pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, {
      virt_text = { { ' keep holding ␣ …', 'DictationHint' } },
      virt_text_pos = 'eol',
    })
    if ok then
      hint = { buf = buf, id = id }
    end
  end)
end

function M.clear_hint()
  vim.schedule(function()
    if hint and api.nvim_buf_is_valid(hint.buf) then
      pcall(api.nvim_buf_del_extmark, hint.buf, ns, hint.id)
    end
    hint = nil
  end)
end

local function draw(text)
  if not rec or not api.nvim_buf_is_valid(rec.buf) then
    return
  end
  local ok, id = pcall(api.nvim_buf_set_extmark, rec.buf, ns, rec.row, 0, {
    id = rec.id,
    virt_text = { { text, 'DictationHint' } },
    virt_text_pos = 'eol',
  })
  if ok then
    rec.id = id
  end
end

-- remaining fns are called from scheduled contexts and run directly

function M.show_recording(buf, row)
  M.clear_hint()
  rec = { buf = buf, row = row }
  draw('🎙 ' .. LEVELS[1])
end

function M.level(rms)
  if not rec then
    return
  end
  local idx = math.min(#LEVELS, math.max(1, math.floor((rms or 0) * 25) + 1))
  draw('🎙 ' .. LEVELS[idx])
end

function M.show_finalizing()
  draw('… transcribing')
end

function M.clear()
  M.clear_hint()
  if rec and rec.id and api.nvim_buf_is_valid(rec.buf) then
    pcall(api.nvim_buf_del_extmark, rec.buf, ns, rec.id)
  end
  rec = nil
end

return M
