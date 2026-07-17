-- Dictation state machine: idle -> recording -> finalizing -> idle.
local M = {}
local api = vim.api
local uv = vim.uv

local buffer = require('dictation.buffer')

local cfg
local state = 'idle'
local sid = 0
local watchdog
local finalize_timer
local interim_text
local target_buf

function M.setup(config)
  cfg = config
end

function M.is_recording()
  return state == 'recording'
end

function M.is_busy()
  return state ~= 'idle'
end

function M.status()
  return ({ idle = '', recording = '● dictating', finalizing = '… transcribing' })[state]
end

local function stop_timer(t)
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

local function cleanup(remove_text)
  stop_timer(watchdog)
  watchdog = nil
  stop_timer(finalize_timer)
  finalize_timer = nil
  if remove_text then
    buffer.remove()
  else
    buffer.cleanup()
  end
  require('dictation.ui').clear()
  pcall(api.nvim_del_augroup_by_name, 'DictationBuf')
  interim_text = nil
  target_buf = nil
  state = 'idle'
end

function M.detect_mic_cmd()
  if vim.fn.executable('pw-record') == 1 then
    return { 'pw-record', '--rate=16000', '--channels=1', '--format=s16', '-' }
  elseif vim.fn.executable('arecord') == 1 then
    return { 'arecord', '-q', '-f', 'S16_LE', '-r', '16000', '-c', '1', '-t', 'raw', '-' }
  elseif vim.fn.executable('parec') == 1 then
    return { 'parec', '--format=s16le', '--rate=16000', '--channels=1' }
  elseif vim.fn.executable('rec') == 1 then
    return { 'rec', '-q', '-t', 'raw', '-r', '16000', '-e', 'signed', '-b', '16', '-c', '1', '-' }
  end
  return nil
end

--- Runs in vim.schedule context. strip = spaces the warmup chain inserted.
function M.activate(strip)
  if state ~= 'idle' then
    return
  end
  if not api.nvim_get_mode().mode:match('^i') then
    return
  end
  local buf = api.nvim_get_current_buf()
  if not vim.bo[buf].modifiable then
    return
  end
  local sidecar = require('dictation.sidecar')
  if not sidecar.ensure() then
    return
  end

  local win = api.nvim_get_current_win()
  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1] - 1, pos[2]

  -- strip warmup spaces, but never more than actually sit before the cursor
  local line = api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
  local trailing = #line:sub(1, col):match(' *$')
  local n = math.min(strip, trailing)
  if n > 0 then
    api.nvim_buf_set_text(buf, row, col - n, row, col, { '' })
    col = col - n
    api.nvim_win_set_cursor(win, { row + 1, col })
  end

  buffer.attach(buf, row, col)
  target_buf = buf
  sid = sid + 1
  interim_text = nil
  state = 'recording'

  local options = { micCmd = cfg.audio.mic_cmd or M.detect_mic_cmd() }
  if cfg.provider == 'deepgram' then
    options.apiKeyEnv = cfg.deepgram.api_key_env
    options.apiKeyCmd = cfg.deepgram.api_key_cmd
    options.deepgram = {
      endpoint = cfg.deepgram.endpoint,
      model = cfg.deepgram.model,
      language = cfg.deepgram.language,
      smart_format = cfg.deepgram.smart_format,
      keyterms = cfg.deepgram.keyterms,
    }
  elseif cfg.provider == 'assemblyai' then
    options.apiKeyEnv = cfg.assemblyai.api_key_env
    options.apiKeyCmd = cfg.assemblyai.api_key_cmd
    options.assemblyai = {
      endpoint = cfg.assemblyai.endpoint,
      token_endpoint = cfg.assemblyai.token_endpoint,
      keyterms = cfg.assemblyai.keyterms,
    }
  end
  sidecar.send({ cmd = 'start', session = sid, provider = cfg.provider, options = options })
  require('dictation.ui').show_recording(buf, row)

  local keyhold = require('dictation.keyhold')
  watchdog = uv.new_timer()
  watchdog:start(cfg.hold.poll_interval_ms, cfg.hold.poll_interval_ms, function()
    if state ~= 'recording' then
      return
    end
    local gap = (uv.hrtime() - keyhold.last_space_ns) / 1e6
    if gap > cfg.hold.release_timeout_ms then
      vim.schedule(M.stop)
    end
  end)

  api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
    buffer = buf,
    group = api.nvim_create_augroup('DictationBuf', { clear = true }),
    callback = function()
      M.cancel('buffer gone')
    end,
  })
end

function M.stop()
  if state ~= 'recording' then
    return
  end
  state = 'finalizing'
  stop_timer(watchdog)
  watchdog = nil
  require('dictation.ui').show_finalizing()
  require('dictation.sidecar').send({ cmd = 'stop', session = sid })
  finalize_timer = uv.new_timer()
  finalize_timer:start(cfg.finalize_timeout_ms, 0, function()
    vim.schedule(function()
      if state ~= 'finalizing' then
        return
      end
      if interim_text and interim_text ~= '' then
        vim.notify('dictation: STT timed out; committing interim transcript', vim.log.levels.WARN)
        M._commit(interim_text)
      else
        vim.notify('dictation: STT timed out with no transcript', vim.log.levels.ERROR)
        require('dictation.sidecar').send({ cmd = 'cancel', session = sid })
        cleanup(true)
      end
    end)
  end)
end

--- Sidecar event dispatch. Always called in vim.schedule context.
function M.on_event(msg)
  if msg.event == 'ready' then
    return
  end
  if msg.session ~= sid then
    return -- stale event from a previous session
  end
  if msg.event == 'interim' then
    if state == 'recording' or state == 'finalizing' then
      interim_text = msg.text
      buffer.write_interim(msg.text)
    end
  elseif msg.event == 'final' then
    if state == 'finalizing' then
      M._commit(msg.text)
    end
  elseif msg.event == 'level' then
    if state == 'recording' then
      require('dictation.ui').level(msg.rms)
    end
  elseif msg.event == 'error' then
    vim.notify('dictation: ' .. (msg.message or 'unknown error'), msg.fatal and vim.log.levels.ERROR or vim.log.levels.WARN)
    if msg.fatal then
      if state == 'finalizing' and interim_text and interim_text ~= '' then
        M._commit(interim_text)
      elseif state ~= 'idle' then
        cleanup(true)
      end
    end
  end
end

function M.on_sidecar_exit(code)
  if state ~= 'idle' then
    vim.notify(('dictation: sidecar exited unexpectedly (code %d)'):format(code or -1), vim.log.levels.ERROR)
    cleanup(true)
  end
end

function M._commit(text)
  stop_timer(finalize_timer)
  finalize_timer = nil
  if not text or text == '' then
    vim.notify('dictation: no speech detected', vim.log.levels.INFO)
    cleanup(true)
    return
  end
  local ok, erow, ecol = buffer.write_final(text)
  if not ok then
    vim.fn.setreg('d', text)
    vim.notify('dictation: buffer changed during transcription — transcript saved to register "d', vim.log.levels.WARN)
  else
    -- move the cursor after the dictated text, but only if the user is
    -- still parked on the dictation range
    if api.nvim_get_current_buf() == target_buf then
      local cur = api.nvim_win_get_cursor(0)
      if buffer.pos_in_range(cur[1] - 1, cur[2]) then
        pcall(api.nvim_win_set_cursor, 0, { erow + 1, ecol })
      end
    end
  end
  cleanup(false)
end

function M.on_insert_leave()
  -- leaving insert while recording aborts; a finalizing session is past the
  -- push-to-talk phase and is left to commit at its anchor
  if state == 'recording' then
    M.cancel('insert-leave')
  end
end

function M.cancel(_reason)
  if state == 'idle' then
    return
  end
  require('dictation.sidecar').send({ cmd = 'cancel', session = sid })
  cleanup(true)
end

return M
