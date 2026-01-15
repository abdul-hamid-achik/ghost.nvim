-- haiku.nvim/lua/haiku/cache.lua
-- LRU cache for completion results

local M = {}

-- Cache storage
local cache = {} -- key -> { value, timestamp }
local order = {} -- Array of keys, most recent at end
local max_size = 50
local ttl = 300 -- Time-to-live in seconds (0 = no expiry)

--- Generate a cache key from context.
---@param ctx table Context from context.build()
---@return string key
function M.make_key(ctx)
  -- Use last N characters of before_cursor + first N of after_cursor + filetype
  -- This creates a reasonably unique key for the cursor position
  local prefix_tail = ctx.before_cursor:sub(-300)
  local suffix_head = ctx.after_cursor:sub(1, 100)

  -- Use a null byte as delimiter to prevent collision between different combinations
  -- e.g., "a|b" + "c" vs "a" + "b|c" would previously both produce "a|b|c"
  local key_str = ctx.filetype .. "\0" .. prefix_tail .. "\0" .. suffix_head

  -- Hash the key to keep it manageable and prevent any edge case collisions
  return vim.fn.sha256(key_str)
end

--- Get a value from the cache.
---@param key string The cache key
---@return string|nil value The cached value or nil
function M.get(key)
  local entry = cache[key]
  if entry then
    -- Check TTL expiration
    if ttl > 0 then
      local age = os.time() - entry.timestamp
      if age > ttl then
        -- Entry expired, remove it
        cache[key] = nil
        for i, k in ipairs(order) do
          if k == key then
            table.remove(order, i)
            break
          end
        end
        return nil
      end
    end
    -- Move to end of order (most recently used)
    M.touch(key)
    return entry.value
  end
  return nil
end

--- Set a value in the cache.
---@param key string The cache key
---@param value string The value to cache
function M.set(key, value)
  -- If key exists, just update
  if cache[key] then
    cache[key] = { value = value, timestamp = os.time() }
    M.touch(key)
    return
  end

  -- Evict oldest if at capacity
  while #order >= max_size do
    local oldest_key = table.remove(order, 1)
    cache[oldest_key] = nil
  end

  -- Add new entry
  cache[key] = { value = value, timestamp = os.time() }
  table.insert(order, key)
end

--- Move a key to the end of the order list (mark as recently used).
---@param key string The cache key
function M.touch(key)
  for i, k in ipairs(order) do
    if k == key then
      table.remove(order, i)
      table.insert(order, key)
      break
    end
  end
end

--- Clear the entire cache.
function M.clear()
  cache = {}
  order = {}
end

--- Get cache statistics.
---@return table stats { size, max_size, ttl, oldest_age, newest_age }
function M.stats()
  local now = os.time()
  local oldest_age = 0
  local newest_age = math.huge

  for _, entry in pairs(cache) do
    local age = now - entry.timestamp
    oldest_age = math.max(oldest_age, age)
    newest_age = math.min(newest_age, age)
  end

  return {
    size = #order,
    max_size = max_size,
    ttl = ttl,
    oldest_age = oldest_age,
    newest_age = newest_age ~= math.huge and newest_age or 0,
  }
end

--- Invalidate cache entries for a specific buffer.
--- Note: Since cache keys are now hashed, this function clears the entire cache.
--- For more granular invalidation, we would need to store filepath metadata with entries.
---@param filepath string The file path to invalidate (currently unused, clears all)
function M.invalidate_file(filepath)
  -- With hashed keys, we can't match by filepath substring anymore.
  -- Clear the entire cache as a safe fallback.
  -- This is acceptable since cache is primarily for very recent completions.
  M.clear()
end

--- Set the maximum cache size.
---@param size number New max size
function M.set_max_size(size)
  max_size = size

  -- Evict if over new limit
  while #order > max_size do
    local oldest_key = table.remove(order, 1)
    cache[oldest_key] = nil
  end
end

--- Set the TTL (time-to-live) for cache entries.
---@param seconds number TTL in seconds (0 = no expiry)
function M.set_ttl(seconds)
  ttl = seconds or 300
end

--- Get the current TTL setting.
---@return number ttl TTL in seconds
function M.get_ttl()
  return ttl
end

--- Get current cache size.
---@return number size
function M.size()
  return #order
end

return M
