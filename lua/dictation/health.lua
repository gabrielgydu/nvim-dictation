local M = {}
local health = vim.health

function M.check()
  health.start('dictation')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim 0.10+ required')
  end

  if vim.fn.executable('deno') == 1 then
    health.ok((vim.fn.systemlist({ 'deno', '--version' })[1] or 'deno') .. ' found')
  else
    health.error('deno not found — required to run the STT sidecar', { 'install deno: https://deno.land' })
  end

  local script = require('dictation.sidecar').script_path()
  if vim.fn.filereadable(script) == 1 then
    health.ok('sidecar script: ' .. script)
  else
    health.error('sidecar script missing: ' .. script)
  end

  local found = {}
  for _, tool in ipairs({ 'pw-record', 'arecord', 'parec', 'rec' }) do
    if vim.fn.executable(tool) == 1 then
      found[#found + 1] = tool
    end
  end
  if #found > 0 then
    health.ok('audio capture: ' .. table.concat(found, ', ') .. ' (using ' .. found[1] .. ')')
  else
    health.error('no audio capture tool found', {
      'install one of: pipewire-utils (pw-record), alsa-utils (arecord), libpulse (parec), sox (rec)',
    })
  end

  local cfg = require('dictation').config
  if not cfg then
    health.warn("require('dictation').setup() has not been called")
    return
  end
  local function check_key(pcfg, label)
    local env = pcfg.api_key_env
    if os.getenv(env) and os.getenv(env) ~= '' then
      health.ok(label .. ': $' .. env .. ' is set')
      return
    end
    if pcfg.api_key_cmd then
      local out = vim.trim(vim.fn.system(pcfg.api_key_cmd))
      if vim.v.shell_error == 0 and out ~= '' then
        health.ok(label .. ': api_key_cmd returns a key')
        return
      end
      health.error(label .. ': $' .. env .. ' unset and api_key_cmd produced nothing')
      return
    end
    health.error(label .. ': $' .. env .. ' is not set', { 'export ' .. env .. '=<your ' .. label .. ' API key>, or set api_key_cmd' })
  end

  -- `stt check` reads stt's config only: no network, no key printed. It runs
  -- as stt.cmd with `check --json` in place of `stream` and what follows,
  -- keeping a --provider option, so it checks what dictation will run.
  local function check_stt(cmd)
    local is_argv = type(cmd) == 'table' and type(cmd[1]) == 'string'
    for _, arg in ipairs(is_argv and cmd or {}) do
      is_argv = is_argv and type(arg) == 'string'
    end
    if not is_argv then
      health.error('stt.cmd must be an argv list', { "e.g. stt = { cmd = { 'stt', 'stream' } }" })
      return
    end
    if vim.fn.executable(cmd[1]) ~= 1 then
      health.error('stt: ' .. cmd[1] .. ' not found', { 'put it on PATH, or set stt.cmd to its full path' })
      return
    end
    local argv
    for i, arg in ipairs(cmd) do
      if arg == 'stream' then
        argv = vim.list_extend(vim.list_slice(cmd, 1, i - 1), { 'check', '--json' })
        for j = i + 1, #cmd do
          if cmd[j] == '--provider' and cmd[j + 1] then
            vim.list_extend(argv, { cmd[j], cmd[j + 1] })
          elseif cmd[j]:match('^%-%-provider=') then
            argv[#argv + 1] = cmd[j]
          end
        end
        break
      end
    end
    if not argv then
      health.warn('stt: cannot check `' .. table.concat(cmd, ' ') .. '`: it has no `stream` argument to swap for `check`')
      return
    end
    local shown = table.concat(argv, ' ')
    local res = vim.system(argv, { text = true }):wait(5000)
    local ok, info = pcall(vim.json.decode, res.stdout or '')
    if not ok or type(info) ~= 'table' or type(info.stream) ~= 'table' then
      health.warn('stt: `' .. shown .. '` gave no readable answer (exit ' .. tostring(res.code) .. ')')
    elseif info.stream.ok then
      health.ok(('stt: provider %s, live model %s'):format(tostring(info.provider), tostring(info.stream.model)))
    else
      health.error('stt: live transcription cannot start: ' .. tostring(info.stream.problem), { 'stt config: ' .. tostring(info.config) })
    end
  end

  if cfg.provider == 'deepgram' then
    check_key(cfg.deepgram, 'Deepgram')
  elseif cfg.provider == 'assemblyai' then
    check_key(cfg.assemblyai, 'AssemblyAI')
  elseif cfg.provider == 'stt' then
    check_stt(cfg.stt.cmd)
  elseif cfg.provider == 'fake' then
    health.info('provider "fake": deterministic test transcripts, no STT')
  else
    health.error('unknown provider: ' .. tostring(cfg.provider))
  end
end

return M
