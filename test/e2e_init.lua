-- Minimal init for the tmux end-to-end test (test/e2e_tmux.sh).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
vim.opt.shortmess:append('I')

local opts = { provider = vim.env.DICT_TEST_PROVIDER or 'fake', spawn = 'eager' }
if vim.env.DICT_TEST_ENDPOINT then
  opts.deepgram = { endpoint = vim.env.DICT_TEST_ENDPOINT }
end
if vim.env.DICT_TEST_MIC then
  opts.audio = { mic_cmd = { 'sh', '-c', vim.env.DICT_TEST_MIC } }
end
if vim.env.DICT_TEST_STT then
  local function list(v)
    return v and vim.split(v, ',', { trimempty = true })
  end
  opts.stt = {
    cmd = { vim.env.DICT_TEST_STT, 'stream' },
    languages = list(vim.env.DICT_TEST_STT_LANGUAGES),
    terms = list(vim.env.DICT_TEST_STT_TERMS),
  }
end
require('dictation').setup(opts)

-- Dump the message history (vim.notify lands there) to a file
vim.api.nvim_create_user_command('DMessages', function(o)
  vim.fn.writefile(vim.split(vim.fn.execute('messages'), '\n'), o.args)
end, { nargs = 1 })

-- Dump ground truth to a file: line 1, session state, register d, extmark count
vim.api.nvim_create_user_command('DDump', function(o)
  local api = vim.api
  local session = require('dictation.session')
  local leftover = 0
  for _, nsname in ipairs({ 'dictation.buffer', 'dictation.ui' }) do
    local id = api.nvim_get_namespaces()[nsname]
    if id then
      leftover = leftover + #api.nvim_buf_get_extmarks(0, id, 0, -1, {})
    end
  end
  vim.fn.writefile({
    vim.fn.getline(1),
    session.status() == '' and 'idle' or session.status(),
    vim.fn.getreg('d'),
    tostring(leftover),
  }, o.args)
end, { nargs = 1 })
