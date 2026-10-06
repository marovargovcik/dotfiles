vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.scrolloff = 8
-- Colors LSP semantic tokens like their treesitter captures, so the two layers
-- do not visibly swap while a server recomputes its tokens after a save.
vim.cmd.colorscheme('catppuccin')
vim.opt.completeopt = { 'menuone', 'noselect', 'popup' }
vim.opt.statusline = "%!v:lua.require'statusline'.render()"

-- cw/cW as dw/yw, not Vi's special-cased ce/cE behavior (:help cpo-_).
vim.opt.cpoptions:remove('_')

vim.pack.add({
  'https://github.com/nvim-treesitter/nvim-treesitter',
  'https://github.com/neovim/nvim-lspconfig',
  'https://github.com/scalameta/nvim-metals',
  'https://github.com/ibhagwan/fzf-lua',
})

-- nvim-treesitter's main branch only installs parsers (no-op when present);
-- highlighting is Neovim's own and has to be started per filetype.
local treesitter_languages = { 'python', 'javascript', 'typescript', 'html', 'css', 'scala' }
require('nvim-treesitter').install(treesitter_languages)
vim.api.nvim_create_autocmd('FileType', {
  pattern = treesitter_languages,
  -- pcall: until the parser is built, start() throws and would abort the other
  -- FileType handlers, LSP attach included.
  callback = function() pcall(vim.treesitter.start) end,
})

-- Python: use the project's own ruff and interpreter from <project>/.venv, so the
-- editor runs the versions the commit hook does, wherever nvim was started.
local function venv_bin(root, name)
  local path = root and vim.fs.joinpath(root, '.venv', 'bin', name)
  return (path and vim.fn.executable(path) == 1) and path or nil
end

-- ruff only attaches (and so only formats on save) where the project pins it in
-- its .venv; a black or flake8 project is left alone.
vim.lsp.config('ruff', {
  root_dir = function(bufnr, on_dir)
    local root = vim.fs.root(bufnr, { 'pyproject.toml', 'ruff.toml', '.ruff.toml' })
    if venv_bin(root, 'ruff') then on_dir(root) end
  end,
  cmd = function(dispatchers, config)
    return vim.lsp.rpc.start({ venv_bin(config.root_dir, 'ruff'), 'server' }, dispatchers)
  end,
})

vim.lsp.config('basedpyright', {
  -- basedpyright defaults to its strictest mode; 'basic' keeps it from arguing with mypy.
  settings = { basedpyright = { analysis = { typeCheckingMode = 'basic' } } },
  before_init = function(_, config)
    local python = venv_bin(config.root_dir, 'python')
    if python then config.settings.python = { pythonPath = python } end
  end,
})

vim.lsp.enable({ 'ts_ls', 'oxlint', 'oxfmt', 'ruff', 'basedpyright' })

-- nvim-metals attaches its own LSP client; do not add metals to lspconfig.
local metals = require('metals')
local metals_config = metals.bare_config()
-- 'on' has Metals send its build server, build target and status messages as
-- metals/status rather than as popups; long-running work arrives as LSP progress.
metals_config.init_options.statusBarProvider = 'on'
metals_config.handlers = { ['metals/status'] = require('statusline').on_metals_status }

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'scala', 'sbt', 'java' },
  callback = function()
    metals.initialize_or_attach(metals_config)
  end,
})

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = ev.buf })

    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    -- Two Python servers attach; hover comes from basedpyright, not ruff.
    if client.name == 'ruff' then client.server_capabilities.hoverProvider = false end
    if client:supports_method('textDocument/completion') then
      vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
    end
  end,
})

-- Only the project formatters format on save; ts_ls and basedpyright never do.
-- Metals runs the project's scalafmt and needs a .scalafmt.conf to do so.
vim.api.nvim_create_autocmd('BufWritePre', {
  callback = function(ev)
    for _, name in ipairs({ 'ruff', 'oxfmt', 'metals' }) do
      if #vim.lsp.get_clients({ bufnr = ev.buf, name = name }) > 0 then
        vim.lsp.buf.format({ bufnr = ev.buf, name = name, timeout_ms = 2000 })
      end
    end
  end,
})

require('fzf-lua').setup({})
vim.keymap.set('n', '<leader>f', '<cmd>FzfLua files<cr>')
vim.keymap.set('n', '<leader>g', '<cmd>FzfLua live_grep<cr>')
vim.keymap.set('n', '<leader>b', '<cmd>FzfLua buffers<cr>',
  { desc = 'Open buffers (currently loaded)' })
vim.keymap.set('n', '<leader>r', '<cmd>FzfLua oldfiles<cr>',
  { desc = 'Recently opened files (MRU)' })
vim.keymap.set('n', '<leader>q', '<cmd>FzfLua diagnostics_workspace<cr>',
  { desc = 'Diagnostics (project-wide, fuzzy)' })
