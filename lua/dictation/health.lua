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

  if cfg.provider == 'deepgram' then
    check_key(cfg.deepgram, 'Deepgram')
  elseif cfg.provider == 'assemblyai' then
    check_key(cfg.assemblyai, 'AssemblyAI')
  elseif cfg.provider == 'fake' then
    health.info('provider "fake": deterministic test transcripts, no STT')
  else
    health.error('unknown provider: ' .. tostring(cfg.provider))
  end
end

return M
