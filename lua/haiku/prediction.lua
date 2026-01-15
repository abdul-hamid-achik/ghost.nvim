-- haiku.nvim/lua/haiku/prediction.lua
-- Next-cursor prediction: track edit patterns and predict next edit location

local M = {}

-- Recent edits history
local recent_edits = {} -- Array of { row, col, before, after, time }
local max_edits = 50

-- Recent accepts for pattern detection
local recent_accepts = {} -- Array of { completion, time }
local max_accepts = 10

--- Record an edit for pattern detection.
---@param location table { row, col }
---@param content table { before, after }
function M.record_edit(location, content)
  table.insert(recent_edits, {
    row = location.row,
    col = location.col,
    before = content.before,
    after = content.after,
    time = vim.uv.now(),
  })

  -- Keep only recent edits
  while #recent_edits > max_edits do
    table.remove(recent_edits, 1)
  end
end

--- Record an accepted completion.
---@param completion table The completion that was accepted
function M.record_accept(completion)
  table.insert(recent_accepts, {
    completion = completion,
    time = vim.uv.now(),
  })

  -- Keep only recent accepts
  while #recent_accepts > max_accepts do
    table.remove(recent_accepts, 1)
  end
end

--- Get recent changes for context.
---@return table changes
function M.get_recent_changes()
  return vim.deepcopy(recent_edits)
end

--- Predict the next edit location based on patterns.
---@return table|nil location { row, col }
function M.predict_next()
  if #recent_edits < 2 then
    return nil
  end

  local last = recent_edits[#recent_edits]
  local prev = recent_edits[#recent_edits - 1]

  -- Pattern 1: Similar consecutive edits (same 'after' content)
  -- This suggests a repetitive replacement task
  if last.after and prev.after and last.after == prev.after then
    -- Find next occurrence of the pattern we're replacing
    -- Guard against empty string which matches everything
    if last.before and #last.before > 0 then
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(bufnr) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        for i = last.row + 1, #lines do
          local line = lines[i]
          local col = line:find(last.before, 1, true)
          -- Validate col is within line bounds
          if col and col <= #line then
            return { row = i, col = col }
          end
        end
      end
    end
  end

  -- Pattern 2: Vertical editing (same column, consecutive rows)
  if last.col == prev.col and last.row == prev.row + 1 then
    return { row = last.row + 1, col = last.col }
  end

  return nil
end

--- Predict likely positions after accepting a completion.
---@param completion table The completion
---@return table positions Array of { offset, type, hint }
function M.predict_positions_in_completion(completion)
  local positions = {}
  local text = completion.text or completion.insert or ""

  if not text or text == "" then
    return positions
  end

  -- Pattern: Empty function call -> cursor inside parens
  local empty_call = text:find("%(%)")
  if empty_call then
    table.insert(positions, {
      offset = empty_call,
      type = "function_args",
      hint = "Add arguments",
    })
  end

  -- Pattern: Empty string -> cursor inside quotes
  local empty_string = text:find('""') or text:find("''")
  if empty_string then
    table.insert(positions, {
      offset = empty_string,
      type = "string_content",
      hint = "Add string",
    })
  end

  -- Pattern: Empty array/object -> cursor inside brackets
  local empty_array = text:find("%[%]")
  if empty_array then
    table.insert(positions, {
      offset = empty_array,
      type = "array_content",
      hint = "Add elements",
    })
  end

  local empty_object = text:find("{}")
  if empty_object then
    table.insert(positions, {
      offset = empty_object,
      type = "object_content",
      hint = "Add properties",
    })
  end

  -- Default: end of completion
  table.insert(positions, {
    offset = #text,
    type = "end",
    hint = nil,
  })

  return positions
end

--- Jump to the predicted next edit location.
function M.jump_to_next()
  local config = require("haiku").config
  -- Add nil checks for nested config access
  if not config or not config.prediction or not config.prediction.enabled then
    return
  end

  local next_loc = M.predict_next()
  if next_loc then
    -- Validate cursor position before setting
    local ok = pcall(vim.api.nvim_win_set_cursor, 0, { next_loc.row, next_loc.col - 1 })
    if ok then
      -- Trigger completion at new location
      vim.defer_fn(function()
        require("haiku.trigger").trigger_now()
      end, 100)
    end
  end
end

--- Clear all recorded data.
function M.clear()
  recent_edits = {}
  recent_accepts = {}
end

--- Get statistics for debugging.
---@return table stats
function M.stats()
  return {
    edit_count = #recent_edits,
    accept_count = #recent_accepts,
    max_edits = max_edits,
    max_accepts = max_accepts,
  }
end

return M
