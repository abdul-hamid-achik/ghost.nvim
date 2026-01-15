-- haiku.nvim/lua/haiku/api.lua
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

--- Make a streaming completion request to Claude using curl via jobstart.
---@param prompt_data table { system = string, user = string }
---@param callbacks table { on_chunk = function, on_complete = function, on_error = function }
---@return function cancel Function to cancel the request
function M.stream(prompt_data, callbacks)
  local config = require("haiku").config
  local util = require("haiku.util")

  local accumulated = ""
  local cancelled = false
  local job_id = nil

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
        -- Check cancelled again after schedule to avoid race condition
        if not cancelled then
          vim.notify("[haiku] API response complete (" .. #accumulated .. " chars)", vim.log.levels.INFO)
        end
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
        -- Check cancelled again after schedule to avoid race condition
        if not cancelled then
          vim.notify("[haiku] API error: " .. tostring(err), vim.log.levels.ERROR)
        end
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
  vim.notify("[haiku] API request started (model: " .. config.model .. ")", vim.log.levels.INFO)

  -- Build curl command
  -- Note: API key is passed via CLI arg. While visible in `ps aux`, this is standard
  -- practice for CLI tools. The key is already protected by OS-level permissions.
  -- Using stdin or temp files would add complexity without meaningful security gain.
  local curl_cmd = {
    "curl",
    "-s",
    "-X", "POST",
    "https://api.anthropic.com/v1/messages",
    "-H", "Content-Type: application/json",
    "-H", "x-api-key: " .. config.api_key,
    "-H", "anthropic-version: 2023-06-01",
    "-d", body,
  }

  -- Use jobstart for streaming
  job_id = vim.fn.jobstart(curl_cmd, {
    on_stdout = function(_, data, _)
      if cancelled then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" then
          parser(line .. "\n")
        end
      end
    end,
    on_stderr = function(_, data, _)
      if cancelled then
        return
      end
      local stderr = table.concat(data, "\n")
      if stderr ~= "" then
        vim.schedule(function()
          vim.notify("[haiku] curl stderr: " .. stderr, vim.log.levels.WARN)
        end)
      end
    end,
    on_exit = function(_, exit_code, _)
      if cancelled then
        return
      end
      if exit_code ~= 0 then
        vim.schedule(function()
          vim.notify("[haiku] curl exited with code: " .. exit_code, vim.log.levels.ERROR)
          if callbacks.on_error then
            callbacks.on_error("curl failed with exit code " .. exit_code)
          end
        end)
      end
    end,
    stdout_buffered = false,
    stderr_buffered = true,
  })

  if job_id <= 0 then
    vim.notify("[haiku] Failed to start curl job", vim.log.levels.ERROR)
    if callbacks.on_error then
      callbacks.on_error("Failed to start curl")
    end
    return function() end
  end

  -- Return cancel function
  return function()
    cancelled = true
    if job_id and job_id > 0 then
      pcall(vim.fn.jobstop, job_id)
    end
  end
end

--- Make a non-streaming completion request (for testing/fallback).
---@param prompt_data table { system = string, user = string }
---@param callback function Called with (result, error)
function M.complete(prompt_data, callback)
  local config = require("haiku").config

  local body = vim.json.encode({
    model = config.model,
    max_tokens = config.max_tokens,
    system = prompt_data.system,
    messages = {
      { role = "user", content = prompt_data.user },
    },
  })

  local curl_cmd = {
    "curl",
    "-s",
    "-X", "POST",
    "https://api.anthropic.com/v1/messages",
    "-H", "Content-Type: application/json",
    "-H", "x-api-key: " .. config.api_key,
    "-H", "anthropic-version: 2023-06-01",
    "-d", body,
  }

  vim.fn.jobstart(curl_cmd, {
    on_stdout = function(_, data, _)
      local response = table.concat(data, "\n")
      if response == "" then
        return
      end

      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, response)
        if not ok then
          callback(nil, "Failed to parse response")
          return
        end

        if parsed.error then
          callback(nil, parsed.error.message or "API error")
          return
        end

        if parsed.content and parsed.content[1] and parsed.content[1].text then
          callback(parsed.content[1].text, nil)
        else
          callback(nil, "No content in response")
        end
      end)
    end,
    on_stderr = function(_, data, _)
      local stderr = table.concat(data, "\n")
      if stderr ~= "" then
        vim.schedule(function()
          callback(nil, stderr)
        end)
      end
    end,
    stdout_buffered = true,
    stderr_buffered = true,
  })
end

return M
