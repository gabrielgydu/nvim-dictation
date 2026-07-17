-- Long-lived deno sidecar that owns the microphone and the STT connection.
-- Protocol: NDJSON both ways (commands on stdin, events on stdout).
local M = {}

local cfg
local job
local ready = false
local remainder = ''

M.stderr_lines = {}

function M.setup(config)
  cfg = config
end

function M.is_ready()
  return ready
end

function M.is_running()
  return job ~= nil
end

function M.script_path()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(src, ':h:h:h') .. '/sidecar/main.ts'
end

local function on_stdout(_, data, _)
  if not data then
    return
  end
  data[1] = remainder .. (data[1] or '')
  remainder = table.remove(data) or ''
  for _, line in ipairs(data) do
    if line ~= '' then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == 'table' then
        if msg.event == 'ready' then
          ready = true
        end
        vim.schedule(function()
          require('dictation.session').on_event(msg)
        end)
      end
    end
  end
end

local function on_stderr(_, data, _)
  if not data then
    return
  end
  for _, line in ipairs(data) do
    if line ~= '' then
      table.insert(M.stderr_lines, line)
      if #M.stderr_lines > 200 then
        table.remove(M.stderr_lines, 1)
      end
      if cfg and cfg.debug then
        vim.schedule(function()
          vim.notify('dictation sidecar: ' .. line, vim.log.levels.DEBUG)
        end)
      end
    end
  end
end

local function disable(msg)
  require('dictation.keyhold').disabled = true
  vim.notify('dictation: ' .. msg .. ' — dictation disabled (see :checkhealth dictation)', vim.log.levels.ERROR)
end

function M.ensure()
  if job then
    return true
  end
  if vim.fn.executable('deno') ~= 1 then
    disable('deno not found')
    return false
  end
  local script = M.script_path()
  if vim.fn.filereadable(script) ~= 1 then
    disable('sidecar script missing: ' .. script)
    return false
  end
  ready = false
  remainder = ''
  job = vim.fn.jobstart({ 'deno', 'run', '--quiet', '--no-lock', '--allow-run', '--allow-net', '--allow-env', script }, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = function(_, code)
      job = nil
      ready = false
      vim.schedule(function()
        require('dictation.session').on_sidecar_exit(code)
      end)
    end,
  })
  if not job or job <= 0 then
    job = nil
    disable('failed to start sidecar')
    return false
  end
  return true
end

function M.send(tbl)
  if not job then
    return false
  end
  return vim.fn.chansend(job, vim.json.encode(tbl) .. '\n') > 0
end

function M.shutdown()
  if job then
    pcall(M.send, { cmd = 'quit' })
    pcall(vim.fn.jobstop, job)
    job = nil
    ready = false
  end
end

return M
