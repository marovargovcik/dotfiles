-- Statusline: file, LSP progress, diagnostics, Metals build status, ruler.
-- Everything LSP-related is keyed by client and shown only in windows whose
-- buffer that client is attached to, so nothing outlives or leaks from a server.
local M = {}

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local BAR_WIDTH = 10
-- Tasks shorter than this never show: an incremental compile begins and ends
-- within milliseconds, and would only make the statusline flicker.
local PROGRESS_DELAY_MS = 200
local LEVEL_HL = { warn = 'DiagnosticWarn', error = 'DiagnosticError' }
local SEPARATOR = '%#NonText# │ %*'

---@type table<integer, table<string|integer, { title: string?, message: string?, percentage: integer?, since: integer }>>
local progress = {}
---@type table<integer, table<string, table>> client id -> statusType -> MetalsStatusParams
local metals = {}

local function escape(text)
  return (text:gsub('%%', '%%%%'))
end

local function highlight(group, text)
  return group and ('%%#%s#%s%%*'):format(group, text) or text
end

-- Redraws while work is in progress, to animate the spinner and to bring in
-- tasks once they outlast PROGRESS_DELAY_MS.
local timer = assert(vim.uv.new_timer())
local function animate()
  for client_id, tasks in pairs(progress) do
    -- A server that died mid-task never sends the matching 'end'.
    if not next(tasks) or not vim.lsp.get_client_by_id(client_id) then progress[client_id] = nil end
  end
  if not next(progress) then timer:stop() end
  vim.cmd.redrawstatus()
end

vim.api.nvim_create_autocmd('LspProgress', {
  group = vim.api.nvim_create_augroup('statusline.progress', {}),
  callback = function(ev)
    local token, value = ev.data.params.token, ev.data.params.value
    -- Only work done progress has a kind; other payloads have no known shape.
    if type(value) ~= 'table' or not value.kind then return end
    local tasks = progress[ev.data.client_id] or {}
    progress[ev.data.client_id] = tasks
    if value.kind == 'end' then
      tasks[token] = nil
    else
      local task = tasks[token] or { since = vim.uv.now() }
      task.title = value.title
      -- A report that omits these leaves the previous values standing.
      task.message = value.message or task.message
      task.percentage = value.percentage or task.percentage
      tasks[token] = task
    end
    if not timer:is_active() then timer:start(0, 100, vim.schedule_wrap(animate)) end
  end,
})

--- Handler for Metals' `metals/status` notification. Replaces nvim-metals' own,
--- which keeps only the text in a global and so cannot tell a connected build
--- server from a failed one: both send the same text at a different level.
function M.on_metals_status(_, status, ctx)
  local by_type = metals[ctx.client_id] or {}
  metals[ctx.client_id] = by_type
  local type = status.statusType or 'metals'
  local previous = by_type[type]
  by_type[type] = not status.hide and status.text and status or nil

  -- The text of a failing build server is still just its name; the reason is
  -- in the tooltip. Say it once, when the server enters that state.
  if type == 'bsp' and LEVEL_HL[status.level] and status.tooltip
      and not (previous and previous.level == status.level) then
    vim.notify(status.tooltip, vim.log.levels[status.level:upper()])
  end
  vim.cmd.redrawstatus()
end

local function progress_component(clients)
  local now = vim.uv.now()
  local oldest, count = nil, 0
  for _, client in ipairs(clients) do
    for _, task in pairs(progress[client.id] or {}) do
      if now - task.since >= PROGRESS_DELAY_MS then
        count = count + 1
        if not oldest or task.since < oldest.since then oldest = task end
      end
    end
  end
  if not oldest then return '' end

  local parts = { SPINNER[math.floor(now / 100) % #SPINNER + 1], escape(oldest.title or '') }
  if oldest.message then parts[#parts + 1] = escape(oldest.message) end
  -- Build servers that cannot measure a compile report 0% until it ends.
  local percentage = oldest.percentage or 0
  if percentage > 0 then
    local done = math.floor(math.min(percentage, 100) / 100 * BAR_WIDTH + 0.5)
    parts[#parts + 1] = highlight('DiagnosticInfo', ('━'):rep(done))
      .. highlight('NonText', ('━'):rep(BAR_WIDTH - done))
    parts[#parts + 1] = ('%d%%%%'):format(percentage)
  end
  if count > 1 then parts[#parts + 1] = ('+%d'):format(count - 1) end
  return table.concat(parts, ' ')
end

local function metals_component(clients)
  local parts = {}
  for _, client in ipairs(clients) do
    if client.name == 'metals' then
      local by_type = metals[client.id] or {}
      -- Metals reports long-running work twice: as LSP progress and as its own
      -- transient message. The progress component already shows it.
      local busy = next(progress[client.id] or {}) ~= nil
      -- A transient message, the build target of the focused file, the build server.
      for _, type in ipairs({ 'metals', 'module', 'bsp' }) do
        local status = by_type[type]
        local text = status and vim.trim(status.text) or ''
        local level_hl = status and LEVEL_HL[status.level]
        if type == 'bsp' and text == '' then
          -- Metals hides the status rather than saying so when it has no connection.
          parts[#parts + 1] = highlight('DiagnosticWarn', 'no build server')
        elseif text == '' or (type == 'metals' and busy) then
          -- nothing to show
        elseif type == 'bsp' then
          -- A connected build server is the normal state; only trouble is worth the space.
          if level_hl then parts[#parts + 1] = highlight(level_hl, escape(text)) end
        else
          parts[#parts + 1] = highlight(level_hl or (type == 'module' and 'NonText'), escape(text))
        end
      end
    end
  end
  return table.concat(parts, SEPARATOR)
end

function M.render()
  local win = vim.g.statusline_winid
  local file, ruler = '%<%f %h%w%m%r', '%-14.(%l,%c%V%) %P'
  if win ~= vim.api.nvim_get_current_win() then return file .. '%=' .. ruler end

  local buf = vim.api.nvim_win_get_buf(win)
  local clients = vim.lsp.get_clients({ bufnr = buf })
  local right = {}
  for _, component in ipairs({
    progress_component(clients),
    vim.diagnostic.status(buf),
    metals_component(clients),
    ruler,
  }) do
    if component ~= '' then right[#right + 1] = component end
  end
  return file .. '%=' .. table.concat(right, SEPARATOR)
end

return M
