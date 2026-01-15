-- haiku.nvim/lua/haiku/completion.lua
-- Core completion engine: orchestrates context, API, and rendering

local M = {}

local util = require("haiku.util")

-- State for tracking current request
local state = {
  request_id = 0, -- Incrementing ID for request validation
  bufnr = nil, -- Buffer where request was made
  row = nil, -- Row where request was made
  col = nil, -- Column where request was made
  prefix = nil, -- Text before cursor when request was made
}

-- Generate unique request IDs
local next_id = util.id_generator()

--- Request a completion for the current cursor position.
---@return function cancel Cancellation function
function M.request()
  local api = require("haiku.api")
  local context_mod = require("haiku.context")
  local render = require("haiku.render")
  local cache = require("haiku.cache")
  local config = require("haiku").config

  -- Generate new request ID
  local request_id = next_id()
  state.request_id = request_id

  -- Capture current state
  local ctx = context_mod.build()
  state.bufnr = ctx.bufnr
  state.row = ctx.row
  state.col = ctx.col
  state.prefix = ctx.before_cursor

  util.log(string.format("Request #%d: row=%d, col=%d", request_id, ctx.row, ctx.col), vim.log.levels.DEBUG)

  -- Check cache
  local cache_key = cache.make_key(ctx)
  local cached = cache.get(cache_key)
  if cached then
    util.log("Cache hit", vim.log.levels.DEBUG)
    local parsed = M.parse_completion(cached, ctx)
    if parsed and M.is_context_valid(request_id) then
      render.add_suggestion(parsed, ctx)
    end
    return function() end
  end

  -- Build prompt
  local prompt = M.build_prompt(ctx)

  -- Make streaming API request
  local cancel = api.stream(prompt, {
    on_chunk = function(accumulated)
      -- Validate context before rendering
      if not M.is_context_valid(request_id) then
        return
      end

      -- Parse and render incrementally
      local parsed = M.parse_completion(accumulated, ctx)
      if parsed then
        render.show(parsed, ctx)
      end
    end,

    on_complete = function(final_text)
      util.log("Request complete", vim.log.levels.DEBUG)

      if not M.is_context_valid(request_id) then
        return
      end

      -- Cache the result
      cache.set(cache_key, final_text)

      -- Final render - add as a suggestion for cycling
      local parsed = M.parse_completion(final_text, ctx)
      if parsed then
        render.add_suggestion(parsed, ctx)
      end
    end,

    on_error = function(err)
      util.log("Request error: " .. tostring(err), vim.log.levels.WARN)
    end,
  })

  return cancel
end

--- Check if the current context is still valid for a request.
---@param request_id number The request ID to validate
---@return boolean valid Whether the context is still valid
function M.is_context_valid(request_id)
  -- Request was superseded
  if request_id ~= state.request_id then
    return false
  end

  -- Buffer changed
  if state.bufnr ~= vim.api.nvim_get_current_buf() then
    return false
  end

  -- Get current cursor
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_row = cursor[1]
  local current_col = cursor[2]

  -- Row changed (user moved to different line)
  if current_row ~= state.row then
    return false
  end

  -- Column moved backwards (user deleted text)
  if current_col < state.col then
    return false
  end

  -- Allow cursor to move forward (user typed more)
  return true
end

--- Build the prompt for Claude.
---@param ctx table Context from context.build()
---@return table prompt { system = string, user = string }
function M.build_prompt(ctx)
  local config = require("haiku").config

  -- Build system prompt
  local system = [[You are a code completion engine embedded in a text editor.

TASK: Complete OR edit the code at <|CURSOR|>.

RULES:
1. Output ONLY the completion/edit, no explanations or markdown
2. If suggesting an EDIT to existing code, use this format:
   <<<DELETE
   [lines to delete]
   >>>
   <<<INSERT
   [lines to insert]
   >>>
3. If suggesting a pure INSERT, just output the text to insert directly
4. Match existing code style exactly (indentation, quotes, semicolons, etc.)
5. Be concise - complete the current thought, don't write essays
6. If there are linter errors nearby, consider fixing them
7. If you see a pattern in recent edits, continue it
8. Never include <|CURSOR|> in your output
9. If no completion is appropriate, output nothing]]

  -- Build user prompt with context
  local parts = {}

  -- File info
  table.insert(parts, string.format("File: %s (%s)", ctx.filename, ctx.filetype))

  -- Treesitter scope context
  if ctx.treesitter_scope then
    table.insert(parts, string.format("Currently in: %s", ctx.treesitter_scope.type))
  end

  -- Diagnostics
  if ctx.diagnostics and #ctx.diagnostics > 0 then
    table.insert(parts, "\nCurrent issues:")
    for _, d in ipairs(ctx.diagnostics) do
      table.insert(parts, string.format("  Line %d [%s]: %s", d.lnum + 1, d.severity, d.message))
    end
  end

  -- LSP symbols (limited)
  if ctx.lsp_symbols and #ctx.lsp_symbols > 0 then
    table.insert(parts, "\nRelevant symbols:")
    for i, sym in ipairs(ctx.lsp_symbols) do
      if i > 10 then
        break
      end -- Limit symbols
      table.insert(parts, string.format("  %s: %s", sym.kind, sym.name))
    end
  end

  -- Other open buffers context
  if ctx.other_buffers and #ctx.other_buffers > 0 then
    table.insert(parts, "\nRelated files:")
    for _, buf in ipairs(ctx.other_buffers) do
      table.insert(parts, string.format("\n--- %s (%s) ---", buf.name, buf.filetype))

      -- Include symbols if available (limit 5)
      if buf.symbols and #buf.symbols > 0 then
        table.insert(parts, "Symbols:")
        for i, sym in ipairs(buf.symbols) do
          if i > 5 then
            break
          end
          table.insert(parts, string.format("  %s: %s", sym.kind, sym.name))
        end
      end

      -- Include snippet (limited to 500 chars)
      if buf.snippet and buf.snippet ~= "" then
        local truncated = buf.snippet:sub(1, 500)
        if #buf.snippet > 500 then
          truncated = truncated .. "\n..."
        end
        table.insert(parts, "```" .. buf.filetype)
        table.insert(parts, truncated)
        table.insert(parts, "```")
      end
    end
  end

  -- Code context
  table.insert(parts, "\n```" .. ctx.filetype)
  table.insert(parts, ctx.before_cursor .. "<|CURSOR|>" .. ctx.after_cursor)
  table.insert(parts, "```")

  table.insert(parts, "\nComplete at <|CURSOR|>:")

  return {
    system = system,
    user = table.concat(parts, "\n"),
  }
end

--- Clean unwanted artifacts from completion text.
---@param text string The text to clean
---@return string cleaned The cleaned text
local function clean_completion_text(text)
  if not text then return "" end

  local cleaned = text
    -- Remove cursor markers
    :gsub("<|CURSOR|>", "")
    -- Remove markdown code fences (```lang at start, ``` at end)
    :gsub("^```%w*\n?", "")
    :gsub("\n?```%s*$", "")
    -- Remove trailing newline
    :gsub("\n$", "")

  return cleaned
end

--- Parse EDIT markers using line-based approach for robustness.
--- Handles edge cases like `>>>>` in content better than regex.
---@param text string The text to parse
---@return string|nil delete_content, string|nil insert_content
local function parse_edit_markers(text)
  local lines = vim.split(text, "\n", { plain = true })
  local delete_lines = {}
  local insert_lines = {}
  local current_section = nil  -- nil, "delete", or "insert"

  for _, line in ipairs(lines) do
    if line == "<<<DELETE" then
      current_section = "delete"
    elseif line == "<<<INSERT" then
      current_section = "insert"
    elseif line == ">>>" then
      current_section = nil
    elseif current_section == "delete" then
      table.insert(delete_lines, line)
    elseif current_section == "insert" then
      table.insert(insert_lines, line)
    end
  end

  local delete_content = #delete_lines > 0 and table.concat(delete_lines, "\n") or nil
  local insert_content = #insert_lines > 0 and table.concat(insert_lines, "\n") or nil

  return delete_content, insert_content
end

--- Parse completion text, detecting if it's INSERT or EDIT.
---@param text string The completion text
---@param ctx table The context
---@return table|nil completion { type = "insert"|"edit", text = string, delete = string?, insert = string? }
function M.parse_completion(text, ctx)
  if not text or text == "" then
    return nil
  end

  -- Check for edit markers using line-based parsing (more robust than regex)
  if text:find("<<<DELETE") or text:find("<<<INSERT") then
    local delete_match, insert_match = parse_edit_markers(text)

    if delete_match or insert_match then
      -- Clean up matches
      delete_match = clean_completion_text(delete_match)
      insert_match = clean_completion_text(insert_match)

      return {
        type = "edit",
        delete = delete_match,
        insert = insert_match,
        raw = text,
      }
    end
  end

  -- Pure insert: clean up the text
  local cleaned = clean_completion_text(text)
    :gsub("^%s*", "") -- Also trim leading whitespace for inserts

  if cleaned == "" then
    return nil
  end

  return {
    type = "insert",
    text = cleaned,
    raw = text,
  }
end

--- Get current request state (for debugging).
---@return table state
function M.get_state()
  return vim.deepcopy(state)
end

return M
