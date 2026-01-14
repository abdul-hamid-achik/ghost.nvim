-- ghost.nvim/lua/ghost/cmp_source.lua
-- nvim-cmp source integration for ghost.nvim

local source = {}

-- Store pending completions
local pending = {
  items = {},
  ctx = nil,
}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_debug_name()
  return "ghost"
end

function source:is_available()
  local ok, ghost = pcall(require, "ghost")
  if not ok then
    return false
  end
  return ghost.is_enabled() and ghost.is_filetype_enabled()
end

function source:get_trigger_characters()
  return { ".", ":", "(", " " }
end

function source:complete(params, callback)
  local ghost = require("ghost")
  if not ghost.is_enabled() then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local context_mod = require("ghost.context")
  local api = require("ghost.api")
  local completion = require("ghost.completion")
  local cache = require("ghost.cache")

  -- Build context
  local ctx = context_mod.build()

  -- Check cache first
  local cache_key = cache.make_key(ctx)
  local cached = cache.get(cache_key)
  if cached then
    local parsed = completion.parse_completion(cached, ctx)
    if parsed then
      vim.notify("[ghost] cmp: cache hit", vim.log.levels.DEBUG)
      local item = self:make_item(parsed, ctx)
      callback({ items = { item }, isIncomplete = false })
      return
    end
  end

  -- Return incomplete immediately, then fetch async
  callback({ items = {}, isIncomplete = true })

  -- Build prompt and make API request
  local prompt = completion.build_prompt(ctx)

  vim.notify("[ghost] cmp: requesting AI completion...", vim.log.levels.INFO)

  api.stream(prompt, {
    on_complete = function(final_text)
      vim.notify("[ghost] cmp: got response", vim.log.levels.INFO)

      -- Cache the result
      cache.set(cache_key, final_text)

      -- Parse and store
      local parsed = completion.parse_completion(final_text, ctx)
      if parsed then
        pending.items = { self:make_item(parsed, ctx) }
        pending.ctx = ctx

        -- Trigger cmp refresh to show the new item
        vim.schedule(function()
          local cmp = require("cmp")
          if cmp.visible() then
            cmp.complete({ reason = cmp.ContextReason.Auto })
          end
        end)
      end
    end,

    on_error = function(err)
      vim.notify("[ghost] cmp: API error - " .. tostring(err), vim.log.levels.WARN)
    end,
  })
end

function source:make_item(comp, ctx)
  local cmp = require("cmp")

  -- Get the text to insert
  local text
  if comp.type == "insert" then
    text = comp.text
  else
    text = comp.insert or ""
  end

  -- Create label (first line, truncated)
  local first_line = (text or ""):match("^[^\n]*") or ""
  local label = first_line:sub(1, 60)
  if #first_line > 60 then
    label = label .. "..."
  end
  if label == "" then
    label = "[AI completion]"
  end

  return {
    label = label,
    insertText = text,
    kind = cmp.lsp.CompletionItemKind.Text,
    detail = "[AI]",
    sortText = "0000", -- Sort to top
    documentation = {
      kind = "markdown",
      value = "**ghost.nvim AI completion**\n\n```" .. (ctx.filetype or "") .. "\n" .. (text or "") .. "\n```",
    },
  }
end

function source.register()
  local has_cmp, cmp = pcall(require, "cmp")
  if not has_cmp then
    return false
  end

  cmp.register_source("ghost", source.new())
  return true
end

return source
