-- haiku.nvim/lua/haiku/render.lua
-- Haiku text and diff display using extmarks

local M = {}

-- Forward declaration for local function
local clear_display

-- Namespace for extmarks
M.namespace = vim.api.nvim_create_namespace("haiku_completion")

-- Current state
local state = {
  completions = {}, -- Array of completions for cycling
  current_index = 0, -- Current index (1-based, 0 means none)
  completion = nil, -- Current completion text
  completion_type = nil, -- "insert" or "edit"
  extmark_id = nil, -- Main extmark ID
  bufnr = nil, -- Buffer where completion is shown
  row = nil, -- Row where completion starts
  col = nil, -- Column where completion starts
  float_win = nil, -- Floating window for diff view
  float_buf = nil, -- Buffer for floating window
}

--- Setup the render module.
function M.setup()
  -- Create autocommand to clear on buffer change
  vim.api.nvim_create_autocmd({ "BufLeave", "BufDelete" }, {
    callback = function(args)
      -- Capture the buffer number from the event, not from state
      -- This prevents issues where state.bufnr might have changed
      local event_bufnr = args.buf
      if state.bufnr and state.bufnr == event_bufnr then
        M.clear()
      end
    end,
  })
end

--- Show a completion as ghost text.
---@param completion table { type = "insert"|"edit", text = string, delete = string?, insert = string? }
---@param ctx table Context with row, col info
function M.show(completion, ctx)
  if not completion then
    M.clear()
    return
  end

  -- Clear any existing display (but keep completions array for cycling)
  clear_display(false)

  local bufnr = vim.api.nvim_get_current_buf()
  local row = ctx.row - 1 -- Convert to 0-indexed
  local col = ctx.col

  -- Store state
  state.bufnr = bufnr
  state.row = row
  state.col = col
  state.completion = completion
  state.completion_type = completion.type

  if completion.type == "insert" then
    M.show_insert(completion.text, bufnr, row, col)
  elseif completion.type == "edit" then
    M.show_edit(completion, bufnr, row, col)
  end
end

--- Show ghost text for pure insertions.
---@param text string The text to insert
---@param bufnr number Buffer number
---@param row number 0-indexed row
---@param col number Column
function M.show_insert(text, bufnr, row, col)
  if not text or text == "" then
    return
  end

  local config = require("haiku").config
  local lines = vim.split(text, "\n", { plain = true })

  -- Limit lines shown
  local max_lines = config.display.max_lines
  if #lines > max_lines then
    lines = vim.list_slice(lines, 1, max_lines)
    lines[#lines] = lines[#lines] .. " ..."
  end

  -- First line: inline virtual text at cursor position
  local first_line = lines[1] or ""
  local virt_text = { { first_line, "HaikuText" } }

  -- Add indicator if multiple suggestions
  if #state.completions > 1 then
    local indicator = string.format(" [%d/%d]", state.current_index, #state.completions)
    table.insert(virt_text, { indicator, "HaikuIndicator" })
  end

  -- Remaining lines: virtual lines below
  local virt_lines = {}
  for i = 2, #lines do
    table.insert(virt_lines, { { lines[i], "HaikuText" } })
  end

  -- Create extmark
  local extmark_opts = {
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = config.display.priority,
  }

  if #virt_lines > 0 then
    extmark_opts.virt_lines = virt_lines
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, row, col, extmark_opts)
end

--- Show diff popup for edit completions.
---@param completion table { delete = string, insert = string }
---@param bufnr number Buffer number
---@param row number 0-indexed row
---@param col number Column
function M.show_edit(completion, bufnr, row, col)
  local config = require("haiku").config
  local lines = {}

  -- Show deleted lines with - prefix
  if completion.delete and completion.delete ~= "" then
    for line in completion.delete:gmatch("[^\n]+") do
      table.insert(lines, { "- " .. line, "HaikuDiffDelete" })
    end
  end

  -- Show inserted lines with + prefix
  if completion.insert and completion.insert ~= "" then
    for line in completion.insert:gmatch("[^\n]+") do
      table.insert(lines, { "+ " .. line, "HaikuDiffAdd" })
    end
  end

  if #lines == 0 then
    return
  end

  -- Create floating buffer
  state.float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.float_buf].bufhidden = "wipe"
  vim.bo[state.float_buf].filetype = "diff"

  -- Set buffer content
  local buf_lines = {}
  for _, item in ipairs(lines) do
    table.insert(buf_lines, item[1])
  end
  vim.api.nvim_buf_set_lines(state.float_buf, 0, -1, false, buf_lines)

  -- Apply highlights
  for i, item in ipairs(lines) do
    vim.api.nvim_buf_add_highlight(state.float_buf, -1, item[2], i - 1, 0, -1)
  end

  -- Calculate window size and position
  local win_width = 0
  for _, line in ipairs(buf_lines) do
    win_width = math.max(win_width, #line)
  end
  win_width = math.min(win_width + 2, vim.o.columns - 10)
  local win_height = math.min(#lines, config.display.max_lines)

  -- Open floating window
  state.float_win = vim.api.nvim_open_win(state.float_buf, false, {
    relative = "cursor",
    row = 1,
    col = 2,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = "rounded",
    focusable = false,
  })

  -- Set window options
  vim.wo[state.float_win].winblend = 10
  vim.wo[state.float_win].cursorline = false

  -- Also show a hint at cursor position
  state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, row, col, {
    virt_text = { { " [edit]", "HaikuText" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = config.display.priority,
  })
end

--- Clear visual elements only (extmarks, floating windows).
---@param reset_state boolean? Whether to reset all state (default true)
clear_display = function(reset_state)
  -- Clear extmarks
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_clear_namespace(state.bufnr, M.namespace, 0, -1)
  end

  -- Close floating window
  if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
    vim.api.nvim_win_close(state.float_win, true)
  end

  -- Delete floating buffer
  if state.float_buf and vim.api.nvim_buf_is_valid(state.float_buf) then
    pcall(vim.api.nvim_buf_delete, state.float_buf, { force = true })
  end

  state.extmark_id = nil
  state.float_win = nil
  state.float_buf = nil

  if reset_state ~= false then
    -- Full reset
    state.completions = {}
    state.current_index = 0
    state.completion = nil
    state.completion_type = nil
    state.bufnr = nil
    state.row = nil
    state.col = nil
  end
end

--- Clear all ghost text and floating windows.
function M.clear()
  clear_display(true)
end

--- Get the current completion.
---@return table|nil completion The current completion or nil
function M.get_current()
  return state.completion
end

--- Get the current completion text (convenience method).
---@return string|nil text The completion text or nil
function M.get_current_text()
  if not state.completion then
    return nil
  end

  if state.completion.type == "insert" then
    return state.completion.text
  elseif state.completion.type == "edit" then
    return state.completion.insert
  end

  return nil
end

--- Check if there's an active completion.
---@return boolean
function M.has_completion()
  return state.completion ~= nil
end

--- Get current state (for debugging).
---@return table
function M.get_state()
  return vim.deepcopy(state)
end

--- Add a new suggestion to the list and display it.
---@param completion table The completion to add
---@param ctx table Context with row, col info
function M.add_suggestion(completion, ctx)
  if not completion then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local row = ctx.row - 1 -- Convert to 0-indexed
  local col = ctx.col

  -- If position changed, clear existing suggestions
  if state.row ~= row or state.col ~= col or state.bufnr ~= bufnr then
    state.completions = {}
    state.current_index = 0
  end

  -- Check for duplicate (by raw text)
  for _, existing in ipairs(state.completions) do
    if existing.raw == completion.raw then
      return -- Skip duplicate
    end
  end

  -- Add to array
  table.insert(state.completions, completion)
  state.current_index = #state.completions

  -- Display this suggestion
  M.show(completion, ctx)
end

--- Get total number of suggestions.
---@return number count
function M.get_suggestion_count()
  return #state.completions
end

--- Get current suggestion index.
---@return number index (1-based, 0 if none)
function M.get_current_index()
  return state.current_index
end

--- Cycle to the next suggestion.
---@return boolean success Whether there was a next suggestion
function M.next_suggestion()
  if #state.completions == 0 then
    return false
  end

  if state.current_index < #state.completions then
    state.current_index = state.current_index + 1
    state.completion = state.completions[state.current_index]
    state.completion_type = state.completion.type
    M.redisplay_current()
    return true
  end

  return false -- At the end
end

--- Cycle to the previous suggestion.
---@return boolean success
function M.prev_suggestion()
  if #state.completions == 0 or state.current_index <= 1 then
    return false
  end

  state.current_index = state.current_index - 1
  state.completion = state.completions[state.current_index]
  state.completion_type = state.completion.type
  M.redisplay_current()
  return true
end

--- Redisplay the current suggestion (after cycling).
function M.redisplay_current()
  if not state.completion or not state.bufnr then
    return
  end

  -- Clear existing display (keep state)
  clear_display(false)

  -- Re-show current
  if state.completion.type == "insert" then
    M.show_insert(state.completion.text, state.bufnr, state.row, state.col)
  elseif state.completion.type == "edit" then
    M.show_edit(state.completion, state.bufnr, state.row, state.col)
  end
end

--- Update completion text in place (for progressive acceptance).
---@param new_text string The remaining text after partial acceptance
function M.update_text(new_text)
  if not state.completion then
    return
  end

  if new_text == "" then
    M.clear()
    return
  end

  -- Update completion and re-render
  if state.completion.type == "insert" then
    state.completion.text = new_text
    -- Re-render at the updated position
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok then
      M.clear()
      return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      M.clear()
      return
    end
    M.clear()
    M.show_insert(new_text, bufnr, cursor[1] - 1, cursor[2])
    state.completion = { type = "insert", text = new_text }
  end
end

return M
