local M = {}

M.config = nil

local defaults = {
  provider = 'assemblyai', -- 'assemblyai' | 'deepgram' | 'stt' | 'fake'
  -- when to start the sidecar process: 'eager' (on setup), 'insert' (first
  -- InsertEnter), 'lazy' (first dictation activation; first recording may
  -- lose ~100ms of audio to deno cold start)
  spawn = 'insert',
  hold = {
    rapid_gap_ms = 120, -- gaps at or below this count as key auto-repeat
    -- gaps at or below this keep the space chain (and its inserted spaces)
    -- alive; must exceed the keyboard repeat *delay* or the initial press's
    -- space leaks into the buffer on activation
    chain_gap_ms = 700,
    activation_rapid_events = 4, -- consecutive rapid gaps needed to activate
    release_timeout_ms = 200, -- silence after last Space event = key released
    poll_interval_ms = 50,
  },
  audio = {
    mic_cmd = nil, -- override, e.g. {'arecord','-q','-f','S16_LE','-r','16000','-c','1','-t','raw','-'}
  },
  assemblyai = {
    endpoint = 'wss://streaming.assemblyai.com/v3/ws',
    token_endpoint = 'https://streaming.assemblyai.com/v3/token',
    keyterms = {},
    api_key_env = 'ASSEMBLYAI_API_KEY',
    api_key_cmd = nil, -- argv list printing the key, e.g. reading a config file
  },
  deepgram = {
    endpoint = 'wss://api.deepgram.com/v1/listen',
    model = 'nova-3',
    language = 'multi',
    smart_format = true,
    keyterms = {},
    api_key_env = 'DEEPGRAM_API_KEY',
    api_key_cmd = nil,
  },
  stt = {
    -- argv of a command that reads raw PCM on stdin and prints `stt stream`
    -- JSON lines; it owns the provider, the key, languages and key terms
    cmd = { 'stt', 'stream' },
    languages = nil, -- language hints, e.g. { 'en', 'de' }; nil = its config, {} = none
    terms = nil, -- key terms, e.g. { 'Neovim' }; nil = its config, {} = none
    terms_file = nil, -- key terms, one per line (for terms with commas); instead of terms
  },
  finalize_timeout_ms = 6000,
  exclude = {
    filetypes = {},
    buftypes = { 'prompt' },
  },
  debug = false,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  local config = M.config

  vim.api.nvim_set_hl(0, 'DictationInterim', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'DictationHint', { link = 'NonText', default = true })

  require('dictation.keyhold').setup(config)
  require('dictation.session').setup(config)
  require('dictation.sidecar').setup(config)
  require('dictation.ui').setup(config)

  vim.keymap.set('i', '<Space>', function()
    return require('dictation.keyhold').on_space()
  end, { expr = true, silent = true, desc = 'dictation: hold to dictate' })

  local aug = vim.api.nvim_create_augroup('Dictation', { clear = true })
  vim.api.nvim_create_autocmd('InsertLeave', {
    group = aug,
    callback = function()
      require('dictation.session').on_insert_leave()
      require('dictation.keyhold').reset()
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = aug,
    callback = function()
      require('dictation.sidecar').shutdown()
    end,
  })

  if config.spawn == 'eager' then
    require('dictation.sidecar').ensure()
  elseif config.spawn == 'insert' then
    vim.api.nvim_create_autocmd('InsertEnter', {
      group = aug,
      once = true,
      callback = function()
        require('dictation.sidecar').ensure()
      end,
    })
  end

  vim.api.nvim_create_user_command('DictationCancel', function()
    require('dictation.session').cancel('user')
  end, { desc = 'Cancel an in-flight dictation' })

  -- any non-space key breaks the warmup chain, so chained space counting
  -- only ever spans uninterrupted space input
  vim.on_key(function(_, typed)
    if typed and typed ~= '' and typed ~= ' ' then
      require('dictation.keyhold').on_other_key()
    end
  end, vim.api.nvim_create_namespace('dictation.on_key'))
end

--- Statusline component: '' | '● dictating' | '… transcribing'
function M.status()
  return require('dictation.session').status()
end

function M.cancel()
  require('dictation.session').cancel('user')
end

return M
