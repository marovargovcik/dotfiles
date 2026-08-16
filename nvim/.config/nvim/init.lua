-- Options
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.showmode = false  -- mode is shown in the statusline instead

-- Make cw/cW behave like dw/yw instead of the special-cased ce/cE-like
-- behavior Vim gives them (see :help cw).
vim.keymap.set('o', 'w', function() vim.cmd('normal! ' .. vim.v.count1 .. 'w') end, { silent = true })

-- Plugins
vim.pack.add({
  'https://github.com/nvim-treesitter/nvim-treesitter',
  'https://github.com/neovim/nvim-lspconfig',
  'https://github.com/scalameta/nvim-metals',
  'https://github.com/ibhagwan/fzf-lua',
  'https://github.com/hrsh7th/nvim-cmp',
  'https://github.com/hrsh7th/cmp-nvim-lsp',
  'https://github.com/nvim-tree/nvim-web-devicons',  -- filetype icons for lualine
  'https://github.com/nvim-lualine/lualine.nvim',
})

-- Treesitter (parsers installed via :TSInstall typescript javascript scala lua)
require('nvim-treesitter').setup({
  highlight = { enable = true },
})

-- Statusline (mode + git branch + file info + diagnostics)
require('lualine').setup({
  options = {
    theme = 'auto',
    icons_enabled = true,
    globalstatus = true,  -- single statusline across all splits
  },
  sections = {
    lualine_a = { 'mode' },                      -- NORMAL / INSERT / VISUAL ...
    lualine_b = { 'branch', 'diff', 'diagnostics' },  -- git branch + changes + LSP diags
    lualine_c = { { 'filename', path = 1 } },    -- relative path
    lualine_x = {
      { function() return vim.g['metals_status'] or '' end },  -- "Compiling X", "Indexing"...
      'filetype',
    },
    lualine_y = { 'progress' },
    lualine_z = { 'location' },                  -- line:col
  },
})

-- TypeScript LSP
vim.lsp.config('*', {
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
})
vim.lsp.enable('ts_ls')

-- Scala LSP (nvim-metals manages its own LSP attachment, do not use lspconfig)
local metals = require('metals')
local metals_config = metals.bare_config()
metals_config.init_options.statusBarProvider = 'on'  -- push status into vim.g.metals_status

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'scala', 'sbt', 'java' },
  callback = function()
    metals.initialize_or_attach(metals_config)
  end,
})

-- LSP keymaps
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local opts = { buffer = ev.buf }
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'K',  vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
  end,
})

-- Completion
local cmp = require('cmp')
cmp.setup({
  sources = { { name = 'nvim_lsp' } },
  mapping = cmp.mapping.preset.insert({
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<CR>']      = cmp.mapping.confirm({ select = true }),
    ['<C-n>']     = cmp.mapping.select_next_item(),
    ['<C-p>']     = cmp.mapping.select_prev_item(),
  }),
})

-- Diagnostics
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float)
vim.keymap.set('n', ']d', vim.diagnostic.goto_next)
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev)
vim.keymap.set('n', '<leader>q', '<cmd>FzfLua diagnostics_workspace<cr>',
  { desc = 'Diagnostics (project-wide, fuzzy)' })
vim.keymap.set('n', '<leader>Q', '<cmd>FzfLua diagnostics_document<cr>',
  { desc = 'Diagnostics (current buffer, fuzzy)' })

-- File browsing
require('fzf-lua').setup({})
vim.keymap.set('n', '<leader>f', '<cmd>FzfLua files<cr>')
vim.keymap.set('n', '<leader>g', '<cmd>FzfLua live_grep<cr>')
vim.keymap.set('n', '<leader>b', '<cmd>FzfLua buffers<cr>',
  { desc = 'Open buffers (currently loaded)' })
vim.keymap.set('n', '<leader>r', '<cmd>FzfLua oldfiles<cr>',
  { desc = 'Recently opened files (MRU)' })

-- lf file manager (no plugin): open lf in a floating window parked on the
-- current file; files picked in lf (open/<enter>/l on a file) open back here.
local function open_lf()
  local file = vim.api.nvim_buf_get_name(0)
  local start = (file ~= '' and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
  local sel = vim.fn.tempname()

  local width  = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines   * 0.9)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
  })

  -- -selection-path makes lf write the picked file(s) and quit instead of
  -- running its own opener, so selections come back to this nvim.
  vim.fn.jobstart({ 'lf', '-selection-path', sel, start }, {
    term = true,
    on_exit = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
        if vim.fn.filereadable(sel) == 1 then
          local paths = vim.fn.readfile(sel)
          vim.fn.delete(sel)
          for _, p in ipairs(paths) do
            if p ~= '' then vim.cmd('edit ' .. vim.fn.fnameescape(p)) end
          end
        end
      end)
    end,
  })
  vim.cmd('startinsert')
end

vim.keymap.set('n', '<leader>l', open_lf, { desc = 'Open lf at current file' })
