-- ghost.nvim/lua/ghost/init.lua
-- Main entry point: setup(), configuration, state management

local M = {}

-- Plugin state
M.enabled = false
M.initialized = false

-- Default configuration
M.defaults = {
  -- API settings
  api_key = nil, -- Will fallback to ANTHROPIC_API_KEY env var
  model = "claude-haiku-4-5",
  max_tokens = 512,

  -- Timing (critical for good DX)
  debounce_ms = 300, -- Wait after typing stops (200-400 sweet spot)
  min_chars = 3, -- Don't trigger on very short inputs
  idle_trigger_ms = 800, -- Also trigger after idle (even mid-line)

  -- Trigger conditions
  trigger = {
    on_insert = true, -- Trigger in insert mode
    on_idle = true, -- Trigger after idle_trigger_ms
    after_accept = true, -- Trigger after accepting (for chaining)
    on_new_line = true, -- Trigger when creating new line
    in_comments = false, -- Disable in comments (configurable)
  },

  -- Context gathering
  context = {
    lines_before = 100, -- Lines before cursor
    lines_after = 50, -- Lines after cursor
    max_file_size = 100000, -- Skip huge files (bytes)
    include_diagnostics = true, -- Include LSP errors/warnings
    include_lsp_symbols = true, -- Include document symbols
    include_treesitter = true, -- Include treesitter scope
    include_recent_changes = true, -- Track recent edits for pattern detection
    other_buffers = {
      enabled = false, -- Include relevant open buffers
      max_buffers = 3, -- Max other buffers to include
      max_lines_per_buffer = 20, -- Max lines from each buffer
      include_same_filetype = true, -- Prioritize same filetype
    },
  },

  -- Keymaps
  keymap = {
    accept = "<Tab>", -- Accept full completion
    accept_word = "<C-Right>", -- Accept next word only
    accept_line = "<C-l>", -- Accept current line only
    next = "<M-]>", -- Cycle to next suggestion
    prev = "<M-[>", -- Cycle to previous
    dismiss = "<C-]>", -- Dismiss (Esc also works)
  },

  -- Display settings
  display = {
    ghost_hl = "Comment", -- Highlight for ghost text
    delete_hl = "DiffDelete", -- Highlight for deleted text (in diffs)
    change_hl = "DiffChange", -- Highlight for changed text
    priority = 1000, -- Extmark priority
    max_lines = 20, -- Don't show huge completions
  },

  -- Filetypes
  enabled_ft = { "*" }, -- All filetypes by default
  disabled_ft = {
    "TelescopePrompt",
    "NvimTree",
    "neo-tree",
    "lazy",
    "mason",
    "help",
    "qf",
    "fugitive",
    "git",
    "gitcommit",
    "DressingInput",
    "DressingSelect",
  },

  -- Advanced features
  prediction = {
    enabled = true, -- Enable next-cursor prediction
    jump_on_accept = false, -- Auto-jump to next edit location
  },
  patterns = {
    detect_repetitive = true, -- Detect and suggest repetitive edits
    max_pattern_edits = 10, -- Max locations to suggest
  },

  -- Cache settings
  cache = {
    max_size = 50, -- Maximum cached entries
    ttl_seconds = 300, -- Time-to-live in seconds (5 minutes, 0 = no expiry)
  },

  -- Limits (extracted magic numbers)
  limits = {
    max_buffer_lines = 10000, -- Skip buffers larger than this
    edit_search_radius = 20, -- Lines to search for edit targets
    max_lsp_symbols = 20, -- Max LSP symbols to include in context
    max_symbol_depth = 2, -- Max nesting depth for LSP symbols
    max_diagnostics = 5, -- Max diagnostics to include in context
  },

  -- Debug
  debug = false,
}

-- Active configuration (populated by setup)
M.config = {}

--- Setup the plugin with user configuration.
---@param opts? table User configuration options
function M.setup(opts)
  local util = require("ghost.util")

  -- Merge user config with defaults
  M.config = util.tbl_deep_extend(M.defaults, opts or {})

  -- Resolve API key from environment if not provided
  -- Priority: config > GHOST_API_KEY > ANTHROPIC_API_KEY
  M.config.api_key = M.config.api_key or vim.env.GHOST_API_KEY or vim.env.ANTHROPIC_API_KEY

  -- Validate API key
  if not M.config.api_key then
    vim.notify(
      "[ghost.nvim] API key required. Set GHOST_API_KEY environment variable or pass api_key in setup().",
      vim.log.levels.ERROR
    )
    return
  end

  -- Setup highlight groups
  M.setup_highlights()

  -- Initialize cache settings
  local cache = require("ghost.cache")
  if M.config.cache then
    cache.set_max_size(M.config.cache.max_size or 50)
    cache.set_ttl(M.config.cache.ttl_seconds or 300)
  end

  -- Initialize modules
  require("ghost.render").setup()
  require("ghost.trigger").setup()
  require("ghost.accept").setup_keymaps()

  -- Mark as initialized and enabled
  M.initialized = true
  M.enabled = true

  util.log("ghost.nvim initialized", vim.log.levels.INFO)
end

--- Setup highlight groups.
function M.setup_highlights()
  local display = M.config.display

  -- Ghost text highlight (defaults to Comment)
  vim.api.nvim_set_hl(0, "GhostText", { link = display.ghost_hl, default = true })

  -- Indicator for multiple suggestions [1/3]
  vim.api.nvim_set_hl(0, "GhostIndicator", { link = "Comment", default = true })

  -- Diff highlights for edit mode
  vim.api.nvim_set_hl(0, "GhostDiffDelete", { link = display.delete_hl, default = true })
  vim.api.nvim_set_hl(0, "GhostDiffChange", { link = display.change_hl, default = true })
  vim.api.nvim_set_hl(0, "GhostDiffAdd", { link = "DiffAdd", default = true })
end

--- Enable the plugin (auto-initializes if needed).
function M.enable()
  if not M.initialized then
    M.setup({})  -- Auto-initialize with defaults
  end
  if not M.initialized then
    -- setup() failed (likely no API key)
    return
  end
  M.enabled = true
  require("ghost.trigger").enable()
  require("ghost.util").log("ghost.nvim enabled", vim.log.levels.INFO)
end

--- Disable the plugin.
function M.disable()
  M.enabled = false
  require("ghost.trigger").disable()
  require("ghost.render").clear()
  require("ghost.util").log("ghost.nvim disabled", vim.log.levels.INFO)
end

--- Toggle the plugin on/off (auto-initializes if needed).
function M.toggle()
  if M.enabled then
    M.disable()
  else
    M.enable()
  end
end

--- Check if the plugin is enabled.
---@return boolean
function M.is_enabled()
  return M.enabled and M.initialized
end

--- Check if current filetype is enabled.
---@param ft? string Filetype to check (defaults to current buffer)
---@return boolean
function M.is_filetype_enabled(ft)
  ft = ft or vim.bo.filetype

  -- Check disabled list first
  if vim.tbl_contains(M.config.disabled_ft, ft) then
    return false
  end

  -- Check enabled list
  local enabled = M.config.enabled_ft
  if vim.tbl_contains(enabled, "*") then
    return true
  end

  return vim.tbl_contains(enabled, ft)
end

--- Get the current status.
---@return table status Status information
function M.status()
  return {
    enabled = M.enabled,
    initialized = M.initialized,
    model = M.config.model,
    api_key_set = M.config.api_key ~= nil,
  }
end

--- Toggle debug mode at runtime.
---@param enabled? boolean If nil, toggles current state
function M.set_debug(enabled)
  if not M.initialized then
    vim.notify("[ghost.nvim] Not initialized", vim.log.levels.WARN)
    return
  end
  if enabled == nil then
    M.config.debug = not M.config.debug
  else
    M.config.debug = enabled
  end
  vim.notify("[ghost.nvim] Debug mode: " .. (M.config.debug and "ON" or "OFF"))
end

return M
