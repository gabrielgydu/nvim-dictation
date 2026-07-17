-- Keyhold timing unit test. Runs headless with a stubbed session module:
--   nvim --headless --clean --cmd "set rtp+=<repo>" -l test/unit_keyhold.lua
local out = assert(io.open(os.getenv('TEST_RESULTS') or '/tmp/dictation_unit_keyhold.txt', 'w'))
local failures = 0

local function check(name, cond, detail)
  out:write((cond and 'PASS  ' or 'FAIL  ') .. name .. (cond and '' or ('  -- ' .. vim.inspect(detail))) .. '\n')
  out:flush()
  if not cond then
    failures = failures + 1
  end
end

-- stub the session module before keyhold ever requires it
local recording = false
local activations = {}
package.loaded['dictation.session'] = {
  is_recording = function()
    return recording
  end,
  is_busy = function()
    return false
  end,
  activate = function(strip)
    activations[#activations + 1] = strip
  end,
}

local cfg = {
  hold = { rapid_gap_ms = 120, chain_gap_ms = 700, activation_rapid_events = 4, release_timeout_ms = 200, poll_interval_ms = 50 },
  exclude = { filetypes = {}, buftypes = {} },
}
local kh = require('dictation.keyhold')
kh.setup(cfg)

-- 1) single tap passes through
check('single tap returns space', kh.on_space() == ' ')
kh.on_other_key()

-- 2) two slow taps pass through, no activation
vim.wait(200)
local a = kh.on_space()
vim.wait(150)
local b = kh.on_space()
vim.wait(50)
check('two slow taps return spaces', a == ' ' and b == ' ' and #activations == 0, { a = a, b = b, act = activations })
kh.on_other_key()

-- 3) rapid stream: 4 warmup spaces inserted, 5th event activates with strip=4
vim.wait(750)
local returns = {}
for i = 1, 6 do
  returns[i] = kh.on_space()
  vim.wait(15)
end
vim.wait(100)
check(
  'rapid stream: warmup through, activation swallows',
  returns[1] == ' ' and returns[2] == ' ' and returns[3] == ' ' and returns[4] == ' ' and returns[5] == '',
  returns
)
check('activation strips all 4 chain spaces', activations[1] == 4, activations)
check('post-activation events swallowed while recording is pending or off', returns[6] == ' ' or returns[6] == '', returns[6])
kh.on_other_key()

-- 4) realistic repeat delay: press, 300ms gap, rapid stream -> strip=5 (leak fix)
vim.wait(750)
local r1 = kh.on_space() -- initial press
vim.wait(300) -- keyboard repeat delay
local r2 = kh.on_space() -- first auto-repeat: not rapid, but chained
local rr = {}
for i = 1, 4 do
  vim.wait(15)
  rr[i] = kh.on_space()
end
vim.wait(100)
check('delay-repeat: warmup spaces pass through', r1 == ' ' and r2 == ' ' and rr[1] == ' ' and rr[2] == ' ' and rr[3] == ' ', { r1, r2, rr })
check('delay-repeat: activation strips all 5 (no leaked space)', activations[2] == 5, activations)
kh.on_other_key()

-- 5) non-space key breaks the chain
vim.wait(750)
kh.on_space()
kh.on_other_key() -- e.g. user typed a letter
local rr2 = {}
for i = 1, 5 do
  vim.wait(15)
  rr2[i] = kh.on_space()
end
vim.wait(100)
check('chain broken by other key: strip counts only post-break spaces', activations[3] == 4, activations)
kh.on_other_key()

-- 6) spaces swallowed while recording
recording = true
check('space swallowed while recording', kh.on_space() == '')
recording = false
kh.on_other_key()

-- 7) excluded buftype passes through untouched
kh.setup(vim.tbl_deep_extend('force', cfg, { exclude = { buftypes = { 'nofile' }, filetypes = {} } }))
vim.bo.buftype = 'nofile'
local excl = {}
for i = 1, 6 do
  excl[i] = kh.on_space()
  vim.wait(15)
end
vim.wait(100)
check('excluded buftype: all spaces pass through', table.concat(excl) == '      ' and #activations == 3, { excl = excl, act = activations })

out:write((failures == 0 and 'ALL PASS' or (failures .. ' FAILURE(S)')) .. '\n')
out:close()
os.exit(failures == 0 and 0 or 1)
