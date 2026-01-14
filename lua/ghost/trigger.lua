-- ghost.nvim/lua/ghost/trigger.lua
-- Smart trigger logic with debouncing and skip conditions

local M = {}

local util = require("ghost.util")

-- Internal state
local state = {
  enabled = false,
  debounced_fn = nil,
  debounce_timer = nil,
  idle_timer = nil,
  cancel_fn = nil, -- Current request cancellation function
  augroup = nil,
}

--- Setup the trigger module.
function M.setup()
  local config = require("ghost").config

  -- Create debounced trigger function
  state.debounced_fn, state.debounce_timer = util.debounce_trailing(function()
    M.request_completion()
  end, config.debounce_ms)

  -- Create autocommand group
  state.augroup = vim.api.nvim_create_augroup("GhostTrigger", { clear = true })

  -- Enable by default
  M.enable()
end

--- Enable trigger autocmds.
function M.enable()
  if state.enabled then
    return
  end
  state.enabled = true

  local config = require("ghost").config

  -- Clear existing autocmds
  vim.api.nvim_clear_autocmds({ group = state.augroup })

  -- Trigger on text change in insert mode
  if config.trigger.on_insert then
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
      group = state.augroup,
      callback = function()
        M.on_text_changed()
      end,
    })
  end

  -- Clear on leaving insert mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = state.augroup,
    callback = function()
      M.cancel()
      require("ghost.render").clear()
    end,
  })

  -- Handle new line creation
  if config.trigger.on_new_line then
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = state.augroup,
      callback = function()
        -- Start idle timer when entering insert mode
        if config.trigger.on_idle then
          M.start_idle_timer()
        end
      end,
    })
  end

  -- Clear on cursor move (optional - can be aggressive)
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = state.augroup,
    callback = function()
      -- Only clear if we moved to a different line (user rejected)
      -- Don't clear for horizontal movement (typing extends the line)
      local render = require("ghost.render")
      local render_state = render.get_state()
      if render_state.row then
        local cursor = vim.api.nvim_win_get_cursor(0)
        if cursor[1] - 1 ~= render_state.row then
          render.clear()
        end
      end
    end,
  })

  -- Prefetch LSP symbols on buffer enter and text changes (non-blocking)
  if config.context.include_lsp_symbols then
    vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged" }, {
      group = state.augroup,
      callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        require("ghost.context").prefetch_symbols(bufnr)
      end,
    })
  end
end

--- Disable trigger autocmds.
function M.disable()
  state.enabled = false
  M.cancel()

  if state.augroup then
    vim.api.nvim_clear_autocmds({ group = state.augroup })
  end
end

--- Handle text change in insert mode.
function M.on_text_changed()
  if not state.enabled then
    return
  end

  if M.should_skip() then
    return
  end

  -- Clear any existing completion when user types
  require("ghost.render").clear()

  -- Cancel pending request
  M.cancel()

  -- Schedule debounced trigger
  if state.debounced_fn then
    state.debounced_fn()
  end

  -- Restart idle timer
  local config = require("ghost").config
  if config.trigger.on_idle then
    M.start_idle_timer()
  end
end

--- Start the idle trigger timer.
function M.start_idle_timer()
  local config = require("ghost").config

  -- Clear existing timer
  util.cleanup_timer(state.idle_timer)

  -- Create new idle timer
  state.idle_timer = vim.uv.new_timer()
  state.idle_timer:start(config.idle_trigger_ms, 0, vim.schedule_wrap(function()
    if state.enabled and vim.fn.mode() == "i" and not M.should_skip() then
      M.request_completion()
    end
  end))
end

--- Check if we should skip triggering.
---@return boolean should_skip
function M.should_skip()
  local ghost = require("ghost")
  local config = ghost.config

  -- Plugin not enabled
  if not ghost.is_enabled() then
    return true
  end

  -- Not in insert mode
  if vim.fn.mode() ~= "i" then
    return true
  end

  -- Filetype disabled
  if not ghost.is_filetype_enabled() then
    return true
  end

  -- Buffer too large
  local lines = vim.api.nvim_buf_line_count(0)
  local max_lines = ghost.config.limits and ghost.config.limits.max_buffer_lines or 10000
  if lines > max_lines then
    return true
  end

  -- Popup menu visible (built-in completion)
  if vim.fn.pumvisible() == 1 then
    return true
  end

  -- Recording macro
  if vim.fn.reg_recording() ~= "" then
    return true
  end

  -- Check minimum characters
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""

  -- Line too short
  if col < config.min_chars then
    return true
  end

  -- Line is empty or only whitespace
  if line:match("^%s*$") then
    return true
  end

  -- Check if in comment (if configured to skip comments)
  if not config.trigger.in_comments and M.in_comment_or_string() then
    return true
  end

  return false
end

--- Check if cursor is in a comment or string using treesitter.
---@return boolean
function M.in_comment_or_string()
  -- Try to get treesitter node
  local ok, node = pcall(vim.treesitter.get_node)
  if not ok or not node then
    return false
  end

  local node_type = node:type()

  -- Common comment/string node types across languages
  if
    node_type:match("comment")
    or node_type:match("string")
    or node_type:match("template_string")
    or node_type == "string_content"
    or node_type == "string_literal"
  then
    return true
  end

  -- Also check parent (cursor might be at the start of string)
  local parent = node:parent()
  if parent then
    local parent_type = parent:type()
    if parent_type:match("comment") or parent_type:match("string") then
      return true
    end
  end

  return false
end

--- Request a completion.
function M.request_completion()
  if M.should_skip() then
    return
  end

  util.log("Triggering completion request", vim.log.levels.DEBUG)

  local completion = require("ghost.completion")
  state.cancel_fn = completion.request()
end

--- Trigger completion immediately (bypass debounce).
function M.trigger_now()
  if M.should_skip() then
    return
  end

  M.cancel()
  M.request_completion()
end

--- Cancel any pending request.
function M.cancel()
  -- Cancel debounce timer
  if state.debounce_timer then
    state.debounce_timer:stop()
  end

  -- Cancel idle timer
  if state.idle_timer then
    state.idle_timer:stop()
  end

  -- Cancel in-flight request
  if state.cancel_fn then
    state.cancel_fn()
    state.cancel_fn = nil
  end
end

--- Cleanup resources.
function M.cleanup()
  M.disable()
  util.cleanup_timer(state.debounce_timer)
  util.cleanup_timer(state.idle_timer)
end

return M
