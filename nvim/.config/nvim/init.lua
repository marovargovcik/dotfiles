vim.opt.number = true
vim.opt.relativenumber = true
-- Absolute and relative number side by side; blank on wrapped continuation lines.
vim.opt.statuscolumn = "%s%4{v:virtnum ? '' : v:lnum} %3{v:virtnum ? '' : v:relnum} "
vim.opt.showmode = false

-- cw/cW as dw/yw, not Vim's special-cased ce/cE behavior (:help cw).
vim.keymap.set('o', 'w', function() vim.cmd('normal! ' .. vim.v.count1 .. 'w') end, { silent = true })

vim.pack.add({
  'https://github.com/nvim-treesitter/nvim-treesitter',
  'https://github.com/neovim/nvim-lspconfig',
  'https://github.com/scalameta/nvim-metals',
  'https://github.com/ibhagwan/fzf-lua',
  'https://github.com/hrsh7th/nvim-cmp',
  'https://github.com/hrsh7th/cmp-nvim-lsp',
  'https://github.com/nvim-tree/nvim-web-devicons',
  'https://github.com/nvim-lualine/lualine.nvim',
})

require('nvim-treesitter').setup({
  highlight = { enable = true },
})

require('lualine').setup({
  options = {
    theme = 'auto',
    icons_enabled = true,
    globalstatus = true,
  },
  sections = {
    lualine_a = { 'mode' },
    lualine_b = { 'branch', 'diff', 'diagnostics' },
    lualine_c = { { 'filename', path = 1 } },
    lualine_x = {
      { function() return vim.g['metals_status'] or '' end },
      'filetype',
    },
    lualine_y = { 'progress' },
    lualine_z = { 'location' },
  },
})

vim.lsp.config('*', {
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
})
vim.lsp.enable('ts_ls')

-- nvim-metals attaches its own LSP client; do not add metals to lspconfig.
local metals = require('metals')
local metals_config = metals.bare_config()
metals_config.init_options.statusBarProvider = 'on'  -- feeds vim.g.metals_status

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'scala', 'sbt', 'java' },
  callback = function()
    metals.initialize_or_attach(metals_config)
  end,
})

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local opts = { buffer = ev.buf }
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'K',  vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
  end,
})

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

vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float)
vim.keymap.set('n', ']d', vim.diagnostic.goto_next)
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev)
vim.keymap.set('n', '<leader>q', '<cmd>FzfLua diagnostics_workspace<cr>',
  { desc = 'Diagnostics (project-wide, fuzzy)' })
vim.keymap.set('n', '<leader>Q', '<cmd>FzfLua diagnostics_document<cr>',
  { desc = 'Diagnostics (current buffer, fuzzy)' })

require('fzf-lua').setup({})
vim.keymap.set('n', '<leader>f', '<cmd>FzfLua files<cr>')
vim.keymap.set('n', '<leader>g', '<cmd>FzfLua live_grep<cr>')
vim.keymap.set('n', '<leader>b', '<cmd>FzfLua buffers<cr>',
  { desc = 'Open buffers (currently loaded)' })
vim.keymap.set('n', '<leader>r', '<cmd>FzfLua oldfiles<cr>',
  { desc = 'Recently opened files (MRU)' })

-- lf in a floating window, parked on the current file; picked files open here.
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

  -- -selection-path: lf writes the picks and quits instead of opening them itself.
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
