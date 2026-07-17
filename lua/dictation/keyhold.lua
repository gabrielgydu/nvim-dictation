-- Hold-detection over terminal key auto-repeat.
--
-- A held Space arrives as: press, one gap of <repeat-delay> ms, then a
-- stream of gaps of <1/repeat-rate> ms. Two thresholds:
--   * rapid_gap_ms: a gap this small is auto-repeat; N consecutive rapid
--     gaps activate dictation.
--   * chain_gap_ms: a gap this small keeps the "chain" alive. chain_count
--     tracks every space inserted by the current chain — including the
--     initial press and the post-delay first repeat — so activation can
--     strip all of them, not just the rapid ones.
local M = {}
local uv = vim.uv

local cfg
local chain_count = 0
local rapid_count = 0
local last_ns = 0
local pending = false -- activation scheduled but not yet run
local hint_shown = false
local exclude_bt, exclude_ft = {}, {}

M.last_space_ns = 0 -- read by the session release watchdog
M.disabled = false

function M.setup(config)
  cfg = config
  exclude_bt, exclude_ft = {}, {}
  for _, b in ipairs(config.exclude.buftypes) do
    exclude_bt[b] = true
  end
  for _, f in ipairs(config.exclude.filetypes) do
    exclude_ft[f] = true
  end
  M.reset()
end

local function clear_hint()
  if hint_shown then
    hint_shown = false
    require('dictation.ui').clear_hint()
  end
end

function M.reset()
  chain_count, rapid_count, last_ns = 0, 0, 0
  clear_hint()
end

function M.on_other_key()
  if chain_count > 0 or rapid_count > 0 or hint_shown then
    M.reset()
  end
end

function M.on_space()
  if M.disabled or exclude_bt[vim.bo.buftype] or exclude_ft[vim.bo.filetype] or vim.fn.reg_executing() ~= '' then
    return ' '
  end

  local session = require('dictation.session')
  local now = uv.hrtime()
  local gap_ms = (now - last_ns) / 1e6
  last_ns = now
  M.last_space_ns = now

  if pending or session.is_recording() then
    return '' -- swallow auto-repeats while recording
  end

  if gap_ms <= cfg.hold.rapid_gap_ms then
    rapid_count = rapid_count + 1
  else
    rapid_count = 0 -- rapid gaps must be consecutive
    if gap_ms > cfg.hold.chain_gap_ms then
      chain_count = 0
    end
  end

  if rapid_count >= cfg.hold.activation_rapid_events then
    local strip = chain_count
    pending = true
    clear_hint()
    chain_count, rapid_count = 0, 0
    -- buffer edits are not allowed inside an expr mapping (E565)
    vim.schedule(function()
      pending = false
      session.activate(strip)
    end)
    return ''
  end

  chain_count = chain_count + 1
  if rapid_count >= 2 and not hint_shown then
    hint_shown = true
    require('dictation.ui').show_hint()
  end
  return ' '
end

return M
