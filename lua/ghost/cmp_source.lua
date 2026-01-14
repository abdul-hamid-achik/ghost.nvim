-- ghost.nvim/lua/ghost/cmp_source.lua
-- nvim-cmp source with debouncing for slow AI completions

local source = {}

-- Singleton state to prevent concurrent requests
local state = {
  timer = nil,
  cancel_fn = nil,
  cached_items = nil,
  cached_ctx_hash = nil,
}

local DEBOUNCE_MS = 400

-- Hash context to detect if we're still at same position
local function hash_ctx(ctx)
  return ctx.bufnr .. ":" .. ctx.row .. ":" .. ctx.col .. ":" .. (ctx.before_cursor:sub(-50) or "")
end

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_debug_name()
  return "ghost"
end

function source:is_available()
  local ok, ghost = pcall(require, "ghost")
  return ok and ghost.is_enabled() and ghost.is_filetype_enabled()
end

function source:complete(params, callback)
  local ghost = require("ghost")
  if not ghost.is_enabled() then
    callback({ items = {} })
    return
  end

  local context_mod = require("ghost.context")
  local ctx = context_mod.build()
  local ctx_hash = hash_ctx(ctx)

  -- Return cached items if context hasn't changed
  if state.cached_items and state.cached_ctx_hash == ctx_hash then
    callback({ items = state.cached_items, isIncomplete = false })
    return
  end

  -- Clear cache for new context
  state.cached_items = nil
  state.cached_ctx_hash = ctx_hash

  -- Cancel pending timer
  if state.timer then
    state.timer:stop()
    state.timer = nil
  end

  -- Return empty but mark as incomplete
  callback({ items = {}, isIncomplete = true })

  -- Debounce: wait for typing to stop before making API request
  state.timer = vim.uv.new_timer()
  state.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    state.timer = nil
    self:do_request(ctx, ctx_hash)
  end))
end

function source:do_request(ctx, ctx_hash)
  -- Cancel previous request if still running
  if state.cancel_fn then
    state.cancel_fn()
    state.cancel_fn = nil
  end

  local api = require("ghost.api")
  local completion = require("ghost.completion")
  local cache = require("ghost.cache")

  -- Check cache first
  local cache_key = cache.make_key(ctx)
  local cached = cache.get(cache_key)
  if cached then
    local parsed = completion.parse_completion(cached, ctx)
    if parsed then
      self:deliver_result(parsed, ctx, ctx_hash)
      return
    end
  end

  -- Build prompt and make API request
  local prompt = completion.build_prompt(ctx)

  vim.notify("[ghost] cmp: API request starting...", vim.log.levels.INFO)

  state.cancel_fn = api.stream(prompt, {
    on_complete = function(final_text)
      vim.notify("[ghost] cmp: got response!", vim.log.levels.INFO)
      cache.set(cache_key, final_text)

      local parsed = completion.parse_completion(final_text, ctx)
      if parsed then
        self:deliver_result(parsed, ctx, ctx_hash)
      end
    end,
    on_error = function(err)
      vim.notify("[ghost] cmp: error - " .. tostring(err), vim.log.levels.WARN)
    end,
  })
end

function source:deliver_result(parsed, ctx, ctx_hash)
  local item = self:make_item(parsed, ctx)

  -- Cache for future calls at same position
  state.cached_items = { item }
  state.cached_ctx_hash = ctx_hash

  -- Trigger cmp to refresh and show our item
  vim.schedule(function()
    local cmp = require("cmp")
    cmp.complete({ reason = cmp.ContextReason.Auto })
  end)
end

function source:make_item(comp, ctx)
  local cmp = require("cmp")
  local text = comp.type == "insert" and comp.text or (comp.insert or "")

  local first_line = (text:match("^[^\n]*") or ""):sub(1, 40)
  if first_line == "" then first_line = "..." end

  -- Add clear AI prefix to make it obvious
  local label = "🤖 " .. first_line

  return {
    label = label,
    insertText = text,
    kind = cmp.lsp.CompletionItemKind.Snippet,
    detail = "ghost.nvim AI",
    sortText = "!0000", -- Sort to very top (! comes before alphanumeric)
    documentation = {
      kind = "markdown",
      value = "**AI Suggestion from ghost.nvim**\n\n```" .. (ctx.filetype or "") .. "\n" .. text .. "\n```",
    },
  }
end

function source.register()
  local ok, cmp = pcall(require, "cmp")
  if not ok then return false end
  cmp.register_source("ghost", source.new())
  return true
end

return source
