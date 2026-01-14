-- ghost.nvim/lua/ghost/context.lua
-- Rich context gathering: code, LSP, treesitter, diagnostics

local M = {}

-- Symbol cache for non-blocking LSP symbol fetching
local symbol_cache = {
  bufnr = nil,
  symbols = {},
  timestamp = 0,
  max_age_ms = 5000, -- 5 second cache
}

--- Build context for the current cursor position.
---@return table context
function M.build()
  local config = require("ghost").config
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]

  local context = {
    -- Buffer info
    bufnr = bufnr,
    filename = vim.fn.expand("%:t"),
    filepath = vim.fn.expand("%:p"),
    filetype = vim.bo[bufnr].filetype,

    -- Cursor position (1-indexed row, 0-indexed col)
    row = row,
    col = col,

    -- Code content
    before_cursor = "",
    after_cursor = "",
    current_line = "",

    -- Rich context
    diagnostics = {},
    treesitter_scope = nil,
    lsp_symbols = {},
    recent_changes = {},
  }

  -- Get buffer content
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total_lines = #lines

  -- Current line
  context.current_line = lines[row] or ""

  -- Calculate context window
  local ctx_config = config.context
  local start_line = math.max(1, row - ctx_config.lines_before)
  local end_line = math.min(total_lines, row + ctx_config.lines_after)

  -- Build before_cursor (includes partial current line)
  local before_lines = {}
  for i = start_line, row - 1 do
    table.insert(before_lines, lines[i])
  end
  local current_before = context.current_line:sub(1, col)
  context.before_cursor = table.concat(before_lines, "\n")
  if #before_lines > 0 then
    context.before_cursor = context.before_cursor .. "\n"
  end
  context.before_cursor = context.before_cursor .. current_before

  -- Build after_cursor (includes rest of current line)
  local current_after = context.current_line:sub(col + 1)
  local after_lines = {}
  for i = row + 1, end_line do
    table.insert(after_lines, lines[i])
  end
  context.after_cursor = current_after
  if #after_lines > 0 then
    context.after_cursor = context.after_cursor .. "\n" .. table.concat(after_lines, "\n")
  end

  -- Get diagnostics
  if ctx_config.include_diagnostics then
    context.diagnostics = M.get_diagnostics(bufnr, row)
  end

  -- Get treesitter scope
  if ctx_config.include_treesitter then
    context.treesitter_scope = M.get_treesitter_scope(bufnr, row - 1, col)
  end

  -- Get LSP symbols
  if ctx_config.include_lsp_symbols then
    context.lsp_symbols = M.get_lsp_symbols(bufnr)
  end

  -- Get recent changes for pattern detection
  if ctx_config.include_recent_changes then
    context.recent_changes = require("ghost.prediction").get_recent_changes()
  end

  -- Get context from other open buffers
  if ctx_config.other_buffers and ctx_config.other_buffers.enabled then
    context.other_buffers = M.get_other_buffers_context(bufnr, context.filetype)
  else
    context.other_buffers = {}
  end

  return context
end

--- Get diagnostics near the cursor.
---@param bufnr number Buffer number
---@param row number 1-indexed row
---@return table diagnostics
function M.get_diagnostics(bufnr, row)
  local config = require("ghost").config
  local limits = config.limits or {}
  local max_diagnostics = limits.max_diagnostics or 5

  local diagnostics = {}
  local all_diags = vim.diagnostic.get(bufnr)

  -- Get diagnostics within 5 lines of cursor
  for _, diag in ipairs(all_diags) do
    if math.abs(diag.lnum - (row - 1)) <= 5 then
      table.insert(diagnostics, {
        lnum = diag.lnum,
        col = diag.col,
        severity = vim.diagnostic.severity[diag.severity] or "Unknown",
        message = diag.message,
        source = diag.source,
      })
    end
  end

  -- Sort by proximity to cursor
  table.sort(diagnostics, function(a, b)
    return math.abs(a.lnum - (row - 1)) < math.abs(b.lnum - (row - 1))
  end)

  -- Limit to most relevant
  if #diagnostics > max_diagnostics then
    diagnostics = vim.list_slice(diagnostics, 1, max_diagnostics)
  end

  return diagnostics
end

--- Get treesitter scope (enclosing function/class/method).
---@param bufnr number Buffer number
---@param row number 0-indexed row
---@param col number 0-indexed column
---@return table|nil scope
function M.get_treesitter_scope(bufnr, row, col)
  -- Check if treesitter is available for this buffer
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  -- Get the tree
  local trees = parser:parse()
  if not trees or #trees == 0 then
    return nil
  end

  local tree = trees[1]
  local root = tree:root()

  -- Find node at cursor
  local node = root:named_descendant_for_range(row, col, row, col)
  if not node then
    return nil
  end

  -- Walk up to find enclosing scope
  local scope_types = {
    -- Functions
    "function_declaration",
    "function_definition",
    "function_expression",
    "arrow_function",
    "method_definition",
    "method_declaration",
    "function_item", -- Rust
    "func_literal", -- Go
    -- Classes/structs
    "class_declaration",
    "class_definition",
    "struct_item", -- Rust
    "type_declaration", -- Go
    "impl_item", -- Rust
    -- Other scopes
    "module",
    "namespace",
  }

  local current = node
  while current do
    local node_type = current:type()

    for _, scope_type in ipairs(scope_types) do
      if node_type == scope_type or node_type:match(scope_type) then
        -- Get the first line of the scope (for context)
        local start_row = current:start()
        local scope_lines = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)
        local first_line = scope_lines[1] or ""

        -- Truncate if too long
        if #first_line > 100 then
          first_line = first_line:sub(1, 100) .. "..."
        end

        return {
          type = node_type,
          line = first_line,
          start_row = start_row,
        }
      end
    end

    current = current:parent()
  end

  return nil
end

--- Get cached symbols or empty if cache is stale/invalid.
---@param bufnr number Buffer number
---@return table symbols
local function get_cached_symbols(bufnr)
  local now = vim.uv.now()
  local age = now - symbol_cache.timestamp
  if symbol_cache.bufnr == bufnr and age < symbol_cache.max_age_ms then
    return symbol_cache.symbols
  end
  return {}
end

--- Get LSP document symbols (non-blocking, returns cached symbols).
---@param bufnr number Buffer number
---@return table symbols
function M.get_lsp_symbols(bufnr)
  -- Return cached symbols if available (non-blocking)
  local cached = get_cached_symbols(bufnr)
  if #cached > 0 then
    return cached
  end

  -- If no cache, try to trigger a prefetch and return empty for now
  -- The next completion request will have symbols available
  M.prefetch_symbols(bufnr)
  return {}
end

--- Prefetch LSP symbols asynchronously and cache them.
---@param bufnr number Buffer number
function M.prefetch_symbols(bufnr)
  -- Don't prefetch if cache is fresh
  local now = vim.uv.now()
  if symbol_cache.bufnr == bufnr and (now - symbol_cache.timestamp) < symbol_cache.max_age_ms then
    return
  end

  -- Get attached LSP clients
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return
  end

  -- Find a client that supports document symbols
  for _, client in ipairs(clients) do
    if client.server_capabilities.documentSymbolProvider then
      local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }

      -- Asynchronous request (non-blocking)
      client.request("textDocument/documentSymbol", params, function(err, result)
        if err or not result then
          return
        end

        -- Flatten symbols and cache them
        local symbols = {}
        M.flatten_symbols(result, symbols, 0)

        symbol_cache.bufnr = bufnr
        symbol_cache.symbols = symbols
        symbol_cache.timestamp = vim.uv.now()
      end, bufnr)

      break -- Only need one client
    end
  end
end

--- Get LSP document symbols synchronously (fallback, blocks).
--- Use this only when you absolutely need symbols immediately.
---@param bufnr number Buffer number
---@return table symbols
function M.get_lsp_symbols_sync(bufnr)
  local symbols = {}

  -- Get attached LSP clients
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return symbols
  end

  -- Find a client that supports document symbols
  for _, client in ipairs(clients) do
    if client.server_capabilities.documentSymbolProvider then
      local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }

      -- Synchronous request (with timeout)
      local result = client.request_sync("textDocument/documentSymbol", params, 500, bufnr)

      if result and result.result then
        M.flatten_symbols(result.result, symbols, 0)
      end

      break -- Only need one client's symbols
    end
  end

  return symbols
end

--- Flatten nested LSP symbols into a list.
---@param lsp_symbols table LSP symbol response
---@param result table Output list
---@param depth number Current nesting depth
function M.flatten_symbols(lsp_symbols, result, depth)
  local config = require("ghost").config
  local limits = config.limits or {}
  local max_depth = limits.max_symbol_depth or 2
  local max_symbols = limits.max_lsp_symbols or 20

  for _, sym in ipairs(lsp_symbols) do
    if #result >= max_symbols then
      break
    end

    -- Get kind name
    local kind_name = vim.lsp.protocol.SymbolKind[sym.kind] or "Unknown"

    table.insert(result, {
      name = sym.name,
      kind = kind_name,
      detail = sym.detail,
      deprecated = sym.deprecated,
    })

    -- Recurse into children
    if depth < max_depth and sym.children then
      M.flatten_symbols(sym.children, result, depth + 1)
    end
  end
end

--- Get indentation of the current line.
---@return string indent The whitespace prefix
function M.get_current_indent()
  local line = vim.api.nvim_get_current_line()
  return line:match("^%s*") or ""
end

--- Get the file size in bytes.
---@param bufnr number Buffer number
---@return number size
function M.get_file_size(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local size = 0
  for _, line in ipairs(lines) do
    size = size + #line + 1 -- +1 for newline
  end
  return size
end

--- Get context from related open buffers.
---@param current_bufnr number Current buffer number
---@param current_filetype string Current filetype
---@return table buffers Array of { name, filepath, filetype, symbols, snippet }
function M.get_other_buffers_context(current_bufnr, current_filetype)
  local config = require("ghost").config
  local ctx_config = config.context.other_buffers

  if not ctx_config or not ctx_config.enabled then
    return {}
  end

  local result = {}
  local bufs = vim.api.nvim_list_bufs()

  -- Score and sort buffers by relevance
  local scored_bufs = {}

  for _, bufnr in ipairs(bufs) do
    -- Skip current buffer
    if bufnr == current_bufnr then
      goto continue
    end

    -- Skip non-loaded, non-listed, or special buffers
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      goto continue
    end
    if not vim.bo[bufnr].buflisted then
      goto continue
    end
    if vim.bo[bufnr].buftype ~= "" then
      goto continue
    end

    local ft = vim.bo[bufnr].filetype
    local filepath = vim.api.nvim_buf_get_name(bufnr)

    -- Skip buffers without a file path
    if filepath == "" then
      goto continue
    end

    -- Calculate relevance score
    local score = 0

    -- Same filetype is high priority
    if ctx_config.include_same_filetype and ft == current_filetype then
      score = score + 10
    end

    -- Same directory gets a bonus
    local current_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(current_bufnr), ":h")
    local buf_dir = vim.fn.fnamemodify(filepath, ":h")
    if current_dir == buf_dir then
      score = score + 5
    end

    -- Recently accessed buffers
    local buf_info = vim.fn.getbufinfo(bufnr)[1]
    if buf_info and buf_info.lastused then
      local age = os.time() - buf_info.lastused
      if age < 60 then
        score = score + 3
      elseif age < 300 then
        score = score + 2
      elseif age < 600 then
        score = score + 1
      end
    end

    if score > 0 then
      table.insert(scored_bufs, { bufnr = bufnr, score = score, filepath = filepath, filetype = ft })
    end

    ::continue::
  end

  -- Sort by score descending
  table.sort(scored_bufs, function(a, b)
    return a.score > b.score
  end)

  -- Take top N buffers
  local max_bufs = ctx_config.max_buffers or 3
  for i = 1, math.min(#scored_bufs, max_bufs) do
    local buf = scored_bufs[i]
    local buf_context = M.extract_buffer_context(buf.bufnr, buf.filepath, buf.filetype, ctx_config)
    if buf_context then
      table.insert(result, buf_context)
    end
  end

  return result
end

--- Extract context from a single buffer.
---@param bufnr number Buffer number
---@param filepath string File path
---@param filetype string File type
---@param ctx_config table Config options
---@return table|nil context { name, filepath, filetype, symbols, snippet }
function M.extract_buffer_context(bufnr, filepath, filetype, ctx_config)
  local filename = vim.fn.fnamemodify(filepath, ":t")

  -- Get LSP symbols for this buffer
  local symbols = M.get_lsp_symbols(bufnr)

  -- Get a snippet (first N lines)
  local max_lines = ctx_config.max_lines_per_buffer or 20
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, max_lines, false)
  local snippet = table.concat(lines, "\n")

  -- Skip if empty
  if #symbols == 0 and snippet == "" then
    return nil
  end

  return {
    name = filename,
    filepath = filepath,
    filetype = filetype,
    symbols = symbols,
    snippet = snippet,
  }
end

return M
