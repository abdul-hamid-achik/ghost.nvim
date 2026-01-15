-- haiku.nvim/lua/haiku/util.lua
-- Utility functions: debounce, throttle, helpers

local M = {}

--- Create a debounced function that delays invoking fn until after ms milliseconds
--- have elapsed since the last time the debounced function was invoked (trailing edge).
---@param fn function The function to debounce
---@param ms number The delay in milliseconds
---@return function debounced The debounced function
---@return userdata timer The timer handle (for cleanup)
function M.debounce_trailing(fn, ms)
  local timer = vim.uv.new_timer()
  local function debounced(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, vim.schedule_wrap(function()
      fn(unpack(args))
    end))
  end
  return debounced, timer
end

--- Create a debounced function that invokes fn on the leading edge (immediate first call).
---@param fn function The function to debounce
---@param ms number The cooldown in milliseconds
---@return function debounced The debounced function
---@return userdata timer The timer handle (for cleanup)
function M.debounce_leading(fn, ms)
  local timer = vim.uv.new_timer()
  local can_call = true
  local function debounced(...)
    if can_call then
      fn(...)
      can_call = false
      timer:start(ms, 0, vim.schedule_wrap(function()
        can_call = true
      end))
    end
  end
  return debounced, timer
end

--- Create a throttled function that only invokes fn at most once per ms milliseconds.
---@param fn function The function to throttle
---@param ms number The minimum interval in milliseconds
---@return function throttled The throttled function
---@return userdata timer The timer handle (for cleanup)
function M.throttle(fn, ms)
  local timer = vim.uv.new_timer()
  local last_call = 0
  local pending_args = nil

  local function throttled(...)
    local now = vim.uv.now()
    local elapsed = now - last_call

    if elapsed >= ms then
      last_call = now
      fn(...)
    else
      pending_args = { ... }
      timer:stop()
      timer:start(ms - elapsed, 0, vim.schedule_wrap(function()
        if pending_args then
          last_call = vim.uv.now()
          fn(unpack(pending_args))
          pending_args = nil
        end
      end))
    end
  end

  return throttled, timer
end

--- Stop and close a timer safely.
---@param timer userdata|nil The timer to cleanup
function M.cleanup_timer(timer)
  if timer then
    -- Wrap in pcall for compatibility with older Neovim versions
    -- and to handle edge cases where timer might be in an invalid state
    pcall(function()
      timer:stop()
    end)
    pcall(function()
      if not timer:is_closing() then
        timer:close()
      end
    end)
  end
end

--- Deep extend tables (convenience wrapper).
---@param ... table Tables to merge
---@return table merged The merged table
function M.tbl_deep_extend(...)
  return vim.tbl_deep_extend("force", ...)
end

--- Check if a value exists in an array.
---@param tbl table The array to search
---@param val any The value to find
---@return boolean found Whether the value exists
function M.tbl_contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then
      return true
    end
  end
  return false
end

--- Split a string by a delimiter.
---@param str string The string to split
---@param sep string The delimiter
---@return table parts The split parts
function M.split(str, sep)
  local parts = {}
  local pattern = string.format("([^%s]+)", sep)
  for part in str:gmatch(pattern) do
    table.insert(parts, part)
  end
  return parts
end

--- Get the current timestamp in milliseconds.
---@return number timestamp
function M.now()
  return vim.uv.now()
end

--- Create a simple incrementing ID generator.
---@return function generator Returns a new ID each call
function M.id_generator()
  local id = 0
  return function()
    id = id + 1
    return id
  end
end

--- Safely call a function with error handling.
---@param fn function The function to call
---@param ... any Arguments to pass
---@return boolean ok Whether the call succeeded
---@return any result The result or error message
function M.pcall_wrap(fn, ...)
  return pcall(fn, ...)
end

--- Log a debug message if debug mode is enabled.
---@param msg string The message to log
---@param level? number vim.log.levels (default INFO)
function M.log(msg, level)
  local config = require("haiku").config
  if config and config.debug then
    vim.notify("[haiku] " .. msg, level or vim.log.levels.DEBUG)
  end
end

return M
