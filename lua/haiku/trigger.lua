-- haiku.nvim/lua/haiku/trigger.lua
-- Smart trigger logic with debouncing and skip conditions

local M = {}

local util = require("haiku.util")

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
  local config = require("haiku").config

  -- Create debounced trigger function
  state.debounced_fn, state.debounce_timer = util.debounce_trailing(function()
    M.request_completion()
  end, config.debounce_ms)

  -- Create autocommand group
  state.augroup = vim.api.nvim_create_augroup("HaikuTrigger", { clear = true })

  -- Enable by default
  M.enable()
end

--- Enable trigger autocmds.
function M.enable()
  if state.enabled then
    return
  end
  state.enabled = true

  local config = require("haiku").config

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
      require("haiku.render").clear()
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
      local render = require("haiku.render")
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
        require("haiku.context").prefetch_symbols(bufnr)
      end,
    })
  end
end

--- Disable trigger autocmds.
function M.disable()
  state.enabled = false
  M.cancel()

  -- Clean up timers properly to prevent leaks
  util.cleanup_timer(state.idle_timer)
  state.idle_timer = nil

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
  require("haiku.render").clear()

  -- Cancel pending request
  M.cancel()

  -- Schedule debounced trigger
  if state.debounced_fn then
    state.debounced_fn()
  end

  -- Restart idle timer
  local config = require("haiku").config
  if config.trigger.on_idle then
    M.start_idle_timer()
  end
end

--- Start the idle trigger timer.
function M.start_idle_timer()
  local config = require("haiku").config

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
  local ghost = require("haiku")
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

  -- Check if nvim-cmp menu is visible
  local has_cmp, cmp = pcall(require, "cmp")
  if has_cmp and cmp.visible() then
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

  -- Wrap node:type() in pcall - node could become invalid if AST is corrupted
  local type_ok, node_type = pcall(function() return node:type() end)
  if not type_ok or not node_type then
    return false
  end

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
  local parent_ok, parent = pcall(function() return node:parent() end)
  if parent_ok and parent then
    local parent_type_ok, parent_type = pcall(function() return parent:type() end)
    if parent_type_ok and parent_type then
      if parent_type:match("comment") or parent_type:match("string") then
        return true
      end
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

  -- Cancel previous request before starting new one to prevent orphaned curl processes
  if state.cancel_fn then
    state.cancel_fn()
    state.cancel_fn = nil
  end

  local completion = require("haiku.completion")
  state.cancel_fn = completion.request()
end

--- Trigger completion immediately (bypass debounce).
function M.trigger_now()
  local ghost = require("haiku")

  -- Always log when manually triggered
  vim.notify("[haiku] trigger_now() called", vim.log.levels.INFO)

  local skip, reason = M.should_skip_verbose()
  if skip then
    vim.notify("[haiku] Skipped: " .. reason, vim.log.levels.WARN)
    return
  end

  vim.notify("[haiku] Requesting completion...", vim.log.levels.INFO)
  M.cancel()
  M.request_completion()
end

--- Check if we should skip triggering (verbose version).
---@return boolean should_skip
---@return string|nil reason
function M.should_skip_verbose()
  local ghost = require("haiku")

  -- Plugin disabled
  if not ghost.is_enabled() then
    return true, "Plugin not enabled"
  end

  -- Not in insert mode
  local mode = vim.fn.mode()
  if mode ~= "i" and mode ~= "ic" and mode ~= "ix" then
    return true, "Not in insert mode (mode=" .. mode .. ")"
  end

  -- Filetype disabled
  if not ghost.is_filetype_enabled() then
    return true, "Filetype disabled (" .. vim.bo.filetype .. ")"
  end

  -- Buffer too large
  local lines = vim.api.nvim_buf_line_count(0)
  local max_lines = ghost.config.limits and ghost.config.limits.max_buffer_lines or 10000
  if lines > max_lines then
    return true, "Buffer too large (" .. lines .. " > " .. max_lines .. ")"
  end

  -- Popup menu visible (built-in completion)
  if vim.fn.pumvisible() == 1 then
    return true, "Popup menu visible"
  end

  -- Check if nvim-cmp menu is visible
  local has_cmp, cmp = pcall(require, "cmp")
  if has_cmp and cmp.visible() then
    return true, "nvim-cmp menu visible"
  end

  -- Recording macro
  if vim.fn.reg_recording() ~= "" then
    return true, "Recording macro"
  end

  -- Current line too short
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local current_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  local min_chars = ghost.config.min_chars or 3
  if #current_line < min_chars then
    return true, "Line too short (" .. #current_line .. " < " .. min_chars .. ")"
  end

  -- Line is empty or whitespace only
  if current_line:match("^%s*$") then
    return true, "Line is empty/whitespace"
  end

  return false, nil
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
