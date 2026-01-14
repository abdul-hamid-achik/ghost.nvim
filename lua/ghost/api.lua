-- ghost.nvim/lua/ghost/api.lua
-- Claude API client with streaming SSE support

local M = {}

--- Create an SSE (Server-Sent Events) parser.
--- Handles partial chunks and extracts text deltas from Claude's streaming response.
---@param on_text function Called with each text chunk
---@param on_complete function Called when streaming is complete
---@param on_error function Called on error
---@return function parser The parser function to feed chunks to
local function create_sse_parser(on_text, on_complete, on_error)
  local buffer = ""

  return function(chunk)
    if not chunk then
      return
    end

    buffer = buffer .. chunk

    -- Process complete lines
    while true do
      local newline_pos = buffer:find("\n")
      if not newline_pos then
        break
      end

      local line = buffer:sub(1, newline_pos - 1)
      buffer = buffer:sub(newline_pos + 1)

      -- Remove carriage return if present (CRLF -> LF)
      line = line:gsub("\r$", "")

      -- Parse SSE data lines
      if line:match("^data: ") then
        local json_str = line:sub(7)

        -- Skip [DONE] marker
        if json_str == "[DONE]" then
          on_complete()
          return
        end

        -- Parse JSON
        local ok, data = pcall(vim.json.decode, json_str)
        if ok and data then
          -- Handle different event types
          if data.type == "content_block_delta" then
            if data.delta and data.delta.type == "text_delta" and data.delta.text then
              on_text(data.delta.text)
            end
          elseif data.type == "message_stop" then
            on_complete()
          elseif data.type == "error" then
            local err_msg = "API error"
            if data.error and data.error.message then
              err_msg = data.error.message
            end
            on_error(err_msg)
          end
          -- Ignore other event types: message_start, content_block_start, content_block_stop, message_delta
        end
      end
    end
  end
end

--- Make a streaming completion request to Claude.
---@param prompt_data table { system = string, user = string }
---@param callbacks table { on_chunk = function, on_complete = function, on_error = function }
---@return function cancel Function to cancel the request
function M.stream(prompt_data, callbacks)
  local config = require("ghost").config
  local util = require("ghost.util")

  -- Load plenary.curl
  local ok, curl = pcall(require, "plenary.curl")
  if not ok then
    vim.schedule(function()
      vim.notify("[ghost.nvim] plenary.nvim is required. Install nvim-lua/plenary.nvim", vim.log.levels.ERROR)
    end)
    if callbacks.on_error then
      callbacks.on_error("plenary.nvim not installed")
    end
    return function() end
  end

  local accumulated = ""
  local cancelled = false
  local job = nil

  -- Create SSE parser
  local parser = create_sse_parser(
    function(text) -- on_text
      if cancelled then
        return
      end
      accumulated = accumulated .. text
      if callbacks.on_chunk then
        vim.schedule(function()
          if not cancelled then
            callbacks.on_chunk(accumulated)
          end
        end)
      end
    end,
    function() -- on_complete
      if cancelled then
        return
      end
      vim.schedule(function()
        vim.notify("[ghost] API response complete (" .. #accumulated .. " chars)", vim.log.levels.INFO)
      end)
      if callbacks.on_complete then
        vim.schedule(function()
          if not cancelled then
            callbacks.on_complete(accumulated)
          end
        end)
      end
    end,
    function(err) -- on_error
      if cancelled then
        return
      end
      vim.schedule(function()
        vim.notify("[ghost] API error: " .. tostring(err), vim.log.levels.ERROR)
      end)
      if callbacks.on_error then
        vim.schedule(function()
          if not cancelled then
            callbacks.on_error(err)
          end
        end)
      end
    end
  )

  -- Build request body
  local body = vim.json.encode({
    model = config.model,
    max_tokens = config.max_tokens,
    stream = true,
    system = prompt_data.system,
    messages = {
      { role = "user", content = prompt_data.user },
    },
  })

  util.log("Making API request to Claude", vim.log.levels.DEBUG)
  vim.schedule(function()
    vim.notify("[ghost] API request started (model: " .. config.model .. ")", vim.log.levels.INFO)
  end)

  -- Make streaming request
  job = curl.post("https://api.anthropic.com/v1/messages", {
    headers = {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = config.api_key,
      ["anthropic-version"] = "2023-06-01",
    },
    body = body,
    stream = function(_, chunk)
      if not cancelled then
        parser(chunk)
      end
    end,
    on_error = function(err)
      vim.schedule(function()
        vim.notify("[ghost] HTTP error: " .. vim.inspect(err), vim.log.levels.ERROR)
      end)
      if not cancelled and callbacks.on_error then
        vim.schedule(function()
          callbacks.on_error(err.message or "Request failed")
        end)
      end
    end,
  })

  -- Return cancel function
  return function()
    cancelled = true
    if job and job.shutdown then
      pcall(job.shutdown, job)
    end
  end
end

--- Make a non-streaming completion request (for testing/fallback).
---@param prompt_data table { system = string, user = string }
---@param callback function Called with (result, error)
function M.complete(prompt_data, callback)
  local config = require("ghost").config

  local ok, curl = pcall(require, "plenary.curl")
  if not ok then
    callback(nil, "plenary.nvim not installed")
    return
  end

  local body = vim.json.encode({
    model = config.model,
    max_tokens = config.max_tokens,
    system = prompt_data.system,
    messages = {
      { role = "user", content = prompt_data.user },
    },
  })

  curl.post("https://api.anthropic.com/v1/messages", {
    headers = {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = config.api_key,
      ["anthropic-version"] = "2023-06-01",
    },
    body = body,
    callback = function(response)
      vim.schedule(function()
        if response.status ~= 200 then
          callback(nil, "API error: " .. response.status)
          return
        end

        local decode_ok, data = pcall(vim.json.decode, response.body)
        if not decode_ok then
          callback(nil, "Failed to parse response")
          return
        end

        if data.content and data.content[1] and data.content[1].text then
          callback(data.content[1].text, nil)
        else
          callback(nil, "No content in response")
        end
      end)
    end,
  })
end

return M
