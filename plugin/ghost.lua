-- ghost.nvim/plugin/ghost.lua
-- Plugin initialization, commands, and autoloading

-- Guard against double-loading
if vim.g.loaded_ghost then
  return
end
vim.g.loaded_ghost = true

-- Check Neovim version (requires 0.10+)
if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("[ghost.nvim] Requires Neovim 0.10 or higher", vim.log.levels.ERROR)
  return
end

-- Lazy load the main module
local function load_ghost()
  return require("ghost")
end

-- Define user commands

-- :Ghost - Toggle ghost completions
vim.api.nvim_create_user_command("Ghost", function()
  load_ghost().toggle()
  local status = load_ghost().is_enabled() and "enabled" or "disabled"
  vim.notify("[ghost.nvim] " .. status, vim.log.levels.INFO)
end, { desc = "Toggle ghost.nvim completions" })

-- :GhostEnable - Enable ghost completions
vim.api.nvim_create_user_command("GhostEnable", function()
  load_ghost().enable()
  vim.notify("[ghost.nvim] enabled", vim.log.levels.INFO)
end, { desc = "Enable ghost.nvim completions" })

-- :GhostDisable - Disable ghost completions
vim.api.nvim_create_user_command("GhostDisable", function()
  load_ghost().disable()
  vim.notify("[ghost.nvim] disabled", vim.log.levels.INFO)
end, { desc = "Disable ghost.nvim completions" })

-- :GhostStatus - Show current status
vim.api.nvim_create_user_command("GhostStatus", function()
  local ghost = load_ghost()
  local status = ghost.status()
  local cache_stats = require("ghost.cache").stats()

  local lines = {
    "ghost.nvim status:",
    "  Enabled: " .. tostring(status.enabled),
    "  Initialized: " .. tostring(status.initialized),
    "  Model: " .. (status.model or "not set"),
    "  API Key: " .. (status.api_key_set and "set" or "NOT SET"),
    "  Cache: " .. cache_stats.size .. "/" .. cache_stats.max_size .. " entries",
  }

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show ghost.nvim status" })

-- :GhostClear - Clear the cache
vim.api.nvim_create_user_command("GhostClear", function()
  require("ghost.cache").clear()
  require("ghost.prediction").clear()
  vim.notify("[ghost.nvim] Cache cleared", vim.log.levels.INFO)
end, { desc = "Clear ghost.nvim cache" })

-- :GhostDebug - Show debug info
vim.api.nvim_create_user_command("GhostDebug", function()
  local ghost = load_ghost()
  local cache = require("ghost.cache")
  local prediction = require("ghost.prediction")
  local completion = require("ghost.completion")
  local render = require("ghost.render")

  -- Helper to add multi-line inspect output
  local lines = {}
  local function add(text)
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  add("=== ghost.nvim Debug Info ===")
  add("")
  add("-- Status --")
  add(vim.inspect(ghost.status()))
  add("")
  add("-- Config --")
  add("Model: " .. ghost.config.model)
  add("Debounce: " .. ghost.config.debounce_ms .. "ms")
  add("Idle trigger: " .. ghost.config.idle_trigger_ms .. "ms")
  add("")
  add("-- Cache --")
  add(vim.inspect(cache.stats()))
  add("")
  add("-- Prediction --")
  add(vim.inspect(prediction.stats()))
  add("")
  add("-- Completion State --")
  add(vim.inspect(completion.get_state()))
  add("")
  add("-- Render State --")
  add(vim.inspect(render.get_state()))

  -- Open in a scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_set_current_buf(buf)
end, { desc = "Show ghost.nvim debug info" })

-- :GhostTrigger - Manually trigger completion
vim.api.nvim_create_user_command("GhostTrigger", function()
  if not load_ghost().is_enabled() then
    vim.notify("[ghost.nvim] Not enabled. Run :GhostEnable first.", vim.log.levels.WARN)
    return
  end
  require("ghost.trigger").trigger_now()
end, { desc = "Manually trigger ghost completion" })
