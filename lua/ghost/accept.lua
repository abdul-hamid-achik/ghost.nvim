-- ghost.nvim/lua/ghost/accept.lua
-- Progressive acceptance: word, line, or full completion

local M = {}

local render = require("ghost.render")

--- Accept the full completion.
---@return boolean success Whether a completion was accepted
function M.accept()
  local completion = render.get_current()
  if not completion then
    return false
  end

  render.clear()

  if completion.type == "insert" then
    M.insert_text(completion.text)
  elseif completion.type == "edit" then
    M.apply_edit(completion)
  end

  -- Trigger next completion if configured
  local config = require("ghost").config
  if config.trigger.after_accept then
    vim.defer_fn(function()
      require("ghost.trigger").trigger_now()
    end, 50)
  end

  -- Record edit for prediction
  if config.prediction.enabled then
    require("ghost.prediction").record_accept(completion)
  end

  return true
end

--- Accept just the next word.
---@return boolean success Whether a word was accepted
function M.accept_word()
  local completion = render.get_current()
  if not completion or completion.type ~= "insert" then
    return false
  end

  local text = completion.text
  if not text or text == "" then
    render.clear()
    return false
  end

  -- Find first word boundary
  -- Match: word characters, or non-space characters, or leading whitespace + first word
  local word = text:match("^(%s*[%w_]+)") -- Leading whitespace + identifier
    or text:match("^(%s*[^%s]+)") -- Leading whitespace + any non-space token
    or text:match("^(%s+)") -- Just whitespace (for indent)

  if not word then
    render.clear()
    return false
  end

  -- Insert the word
  M.insert_text(word)

  -- Update remaining completion
  local remaining = text:sub(#word + 1)
  if remaining == "" or remaining:match("^%s*$") then
    render.clear()
  else
    render.update_text(remaining)
  end

  return true
end

--- Accept just the current line.
---@return boolean success Whether a line was accepted
function M.accept_line()
  local completion = render.get_current()
  if not completion or completion.type ~= "insert" then
    return false
  end

  local text = completion.text
  if not text or text == "" then
    render.clear()
    return false
  end

  -- Find first line
  local newline_pos = text:find("\n")
  local first_line
  local remaining

  if newline_pos then
    first_line = text:sub(1, newline_pos - 1)
    remaining = text:sub(newline_pos + 1)
  else
    first_line = text
    remaining = ""
  end

  -- Insert the line
  M.insert_text(first_line)

  -- Update remaining completion
  if remaining == "" or remaining:match("^%s*$") then
    render.clear()
  else
    render.update_text(remaining)
  end

  return true
end

--- Dismiss the current completion without accepting.
function M.dismiss()
  render.clear()
  require("ghost.trigger").cancel()
end

--- Insert text at the current cursor position.
---@param text string The text to insert
function M.insert_text(text)
  if not text or text == "" then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local start_row = cursor[1]
  local start_col = cursor[2]

  local lines = vim.split(text, "\n", { plain = true })

  if #lines == 1 then
    -- Single line: simple insert
    local row = start_row - 1
    local col = start_col

    local current_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local before = current_line:sub(1, col)
    local after = current_line:sub(col + 1)

    local new_line = before .. text .. after
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })
    vim.api.nvim_win_set_cursor(0, { row + 1, col + #text })
  else
    -- Multi-line: more complex insertion
    local row = start_row - 1
    local col = start_col

    local current_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local before = current_line:sub(1, col)
    local after = current_line:sub(col + 1)

    -- Build new lines
    lines[1] = before .. lines[1]
    lines[#lines] = lines[#lines] .. after

    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, lines)

    -- Position cursor at end of inserted text (before 'after' content)
    local final_row = row + #lines
    local final_col = #lines[#lines] - #after
    vim.api.nvim_win_set_cursor(0, { final_row, final_col })
  end

  -- Record edit for prediction
  local config = require("ghost").config
  if config.prediction and config.prediction.enabled then
    require("ghost.prediction").record_edit(
      { row = start_row, col = start_col },
      { before = "", after = text }
    )
  end
end

--- Find exact multi-line match in buffer lines.
---@param lines table Buffer lines (1-indexed conceptually, but table is 0-indexed)
---@param delete_lines table Lines to find
---@param start_search number Start row (1-indexed)
---@param end_search number End row (1-indexed)
---@return number|nil match_row 1-indexed row where match starts, or nil
local function find_exact_match(lines, delete_lines, start_search, end_search)
  for i = start_search, end_search do
    -- Check if all delete lines match starting at this position
    local all_match = true
    for j, delete_line in ipairs(delete_lines) do
      local buffer_line = lines[i + j - 1]
      if buffer_line == nil or buffer_line ~= delete_line then
        all_match = false
        break
      end
    end
    if all_match then
      return i
    end
  end
  return nil
end

--- Apply an edit (delete + insert).
---@param completion table { delete = string, insert = string }
function M.apply_edit(completion)
  local config = require("ghost").config
  local util = require("ghost.util")
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]

  -- Handle deletion if present
  if completion.delete and completion.delete ~= "" then
    local delete_lines = vim.split(completion.delete, "\n", { plain = true })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local total_lines = #lines

    -- Configurable search radius
    local search_radius = (config.limits and config.limits.edit_search_radius) or 20
    local start_search = math.max(1, row - search_radius)
    local end_search = math.min(total_lines - #delete_lines + 1, row + search_radius)

    -- Try exact multi-line match first
    local match_row = find_exact_match(lines, delete_lines, start_search, end_search)

    if match_row then
      -- Found exact match, delete the lines
      vim.api.nvim_buf_set_lines(bufnr, match_row - 1, match_row - 1 + #delete_lines, false, {})
    else
      -- Fallback: fuzzy match on trimmed first line (for indentation differences)
      local first_line_trimmed = delete_lines[1]:match("^%s*(.-)%s*$")
      local found = false

      for i = start_search, end_search do
        local line_trimmed = (lines[i] or ""):match("^%s*(.-)%s*$")
        if line_trimmed == first_line_trimmed then
          if #delete_lines == 1 then
            -- Single line with whitespace tolerance
            vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
            found = true
            break
          else
            -- Multi-line: check if rest matches with whitespace tolerance
            local all_match = true
            for j = 2, #delete_lines do
              local buf_trimmed = (lines[i + j - 1] or ""):match("^%s*(.-)%s*$")
              local del_trimmed = delete_lines[j]:match("^%s*(.-)%s*$")
              if buf_trimmed ~= del_trimmed then
                all_match = false
                break
              end
            end
            if all_match then
              vim.api.nvim_buf_set_lines(bufnr, i - 1, i - 1 + #delete_lines, false, {})
              found = true
              break
            end
          end
        end
      end

      if not found then
        util.log("Edit mode: Could not find exact match for deletion, skipping delete", vim.log.levels.WARN)
      end
    end
  end

  -- Handle insertion
  if completion.insert and completion.insert ~= "" then
    M.insert_text(completion.insert)
  end

  -- Record edit for prediction (insert_text already records its own, so only record delete here)
  if config.prediction and config.prediction.enabled and completion.delete and completion.delete ~= "" then
    require("ghost.prediction").record_edit(
      { row = row, col = 0 },
      { before = completion.delete, after = "" }
    )
  end
end

--- Setup keymaps for acceptance.
function M.setup_keymaps()
  local config = require("ghost").config
  local keymap = config.keymap

  -- Accept full completion with Tab (skip if empty - user handles it manually)
  if keymap.accept and keymap.accept ~= "" then
    vim.keymap.set("i", keymap.accept, function()
      if render.has_completion() then
        M.accept()
        return ""
      end
      -- Fallback: return the key literally (for other plugins to handle)
      return keymap.accept
    end, { expr = true, silent = true, desc = "Accept ghost completion" })
  end

  -- Accept word with Ctrl+Right (skip if empty)
  if keymap.accept_word and keymap.accept_word ~= "" then
    vim.keymap.set("i", keymap.accept_word, function()
      if render.has_completion() then
        M.accept_word()
      else
        -- Fallback: normal word movement
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-Right>", true, false, true), "n", false)
      end
    end, { silent = true, desc = "Accept ghost word" })
  end

  -- Accept line with Ctrl+L (skip if empty)
  if keymap.accept_line and keymap.accept_line ~= "" then
    vim.keymap.set("i", keymap.accept_line, function()
      if render.has_completion() then
        M.accept_line()
      else
        -- Fallback: normal Ctrl+L behavior (redraw)
        vim.cmd("redraw!")
      end
    end, { silent = true, desc = "Accept ghost line" })
  end

  -- Dismiss with Ctrl+] (skip if empty)
  if keymap.dismiss and keymap.dismiss ~= "" then
    vim.keymap.set("i", keymap.dismiss, function()
      if render.has_completion() then
        M.dismiss()
      end
    end, { silent = true, desc = "Dismiss ghost completion" })
  end

  -- Also dismiss on Escape (but don't override normal Escape behavior)
  vim.keymap.set("i", "<Esc>", function()
    if render.has_completion() then
      M.dismiss()
    end
    -- Always exit insert mode
    return "<Esc>"
  end, { expr = true, silent = true, desc = "Dismiss ghost and exit insert" })

  -- Cycle to next suggestion (M-])
  if keymap.next and keymap.next ~= "" then
    vim.keymap.set("i", keymap.next, function()
      if render.has_completion() then
        local moved = render.next_suggestion()
        if not moved then
          -- At end of suggestions, request a new one
          require("ghost.trigger").trigger_now()
        end
      end
    end, { silent = true, desc = "Next ghost suggestion" })
  end

  -- Cycle to previous suggestion (M-[)
  if keymap.prev and keymap.prev ~= "" then
    vim.keymap.set("i", keymap.prev, function()
      if render.has_completion() then
        render.prev_suggestion()
      end
    end, { silent = true, desc = "Previous ghost suggestion" })
  end
end

return M
