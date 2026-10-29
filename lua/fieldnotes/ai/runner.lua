local config = require("fieldnotes.config")
local notes = require("fieldnotes.notes")

local M = {}

local running = {}

local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))

-- Reads a configured file; a configured path that is missing is an error, not an empty value.
function M.read(path, what)
    if vim.fn.filereadable(path) == 0 then
        error("fieldnotes: " .. what .. " not found: " .. path)
    end
    return table.concat(vim.fn.readfile(path), "\n")
end

-- Loads a prompt (user override or bundled) and fills {{name}} placeholders.
function M.prompt(name, vars)
    local path = config.options.ai.prompts[name] or (plugin_root .. "/prompts/" .. name .. ".md")
    return (M.read(path, "prompt"):gsub("{{(%w+)}}", function(key)
        return vars[key] or error("fieldnotes: unknown placeholder {{" .. key .. "}} in " .. path)
    end))
end

function M.context_text()
    local file = config.options.ai.context_file
    return file and M.read(file, "ai.context_file") or "(none)"
end

function M.repo_dirs()
    return vim.tbl_map(function(repo)
        local dir = config.options.repos_dir .. "/" .. repo
        if vim.fn.isdirectory(dir) == 0 then
            error("fieldnotes: ai.repos entry not found: " .. dir)
        end
        return dir
    end, config.options.ai.repos)
end

-- Returns the note's file when an AI run may start on it.
function M.check(buf)
    local file = vim.api.nvim_buf_get_name(buf)
    if not notes.in_vault(file) then
        vim.notify("fieldnotes: not a vault note", vim.log.levels.WARN)
        return nil
    end
    if running[file] then
        vim.notify("fieldnotes: AI already running for this note", vim.log.levels.WARN)
        return nil
    end
    return file
end

local function temp_file(lines)
    local path = vim.fn.tempname()
    vim.fn.writefile(lines, path)
    return path
end

-- Each backend:
--   prepare(req) -> { cmd, stdin, state }   req: { system, prompt, schema, model, tools, dirs }
--   parse(res, state) -> { data, cost|nil } or nil, error
--   access(tools) / budget() -> dialog text
-- Prompts go through stdin and files, never argv, so large notes or context files cannot hit the argument size limit.
local backends = {
    claude = {
        prepare = function(req)
            local state = { system_file = temp_file(vim.split(req.system, "\n", { plain = true })) }
            local cmd = {
                "claude", "-p",
                "--model", req.model,
                "--append-system-prompt-file", state.system_file,
                "--tools", req.tools,
                "--permission-prompts", "none",
                "--settings", vim.json.encode({ permissions = { deny = config.options.ai.deny } }),
                "--no-session-persistence",
                "--max-budget-usd", tostring(config.options.ai.budget_usd),
                "--output-format", "json",
                "--json-schema", vim.json.encode(req.schema),
            }
            for _, dir in ipairs(req.dirs) do
                vim.list_extend(cmd, { "--add-dir", dir })
            end
            return { cmd = cmd, stdin = req.prompt, state = state }
        end,
        parse = function(res, state)
            vim.fn.delete(state.system_file)
            local ok, out = pcall(vim.json.decode, res.stdout)
            if not ok then
                return nil, "exit " .. res.code .. ": " .. (res.stderr .. res.stdout):sub(1, 200)
            end
            if out.is_error or type(out.structured_output) ~= "table" then
                return nil, tostring(out.result or out.subtype or "no structured output")
            end
            return { data = out.structured_output, cost = out.total_cost_usd }
        end,
        access = function(tools)
            return tools == "" and "no tools, writes from the note only" or "read-only (" .. tools .. "), secrets denied"
        end,
        budget = function()
            return string.format("max $%.2f for this run", config.options.ai.budget_usd)
        end,
    },
    codex = {
        prepare = function(req)
            local function strict(schema)
                if schema.type == "object" then
                    schema.additionalProperties = false
                    for _, prop in pairs(schema.properties) do
                        strict(prop)
                    end
                elseif schema.type == "array" then
                    strict(schema.items)
                end
                return schema
            end
            local state = {
                schema_file = temp_file({ vim.json.encode(strict(vim.deepcopy(req.schema))) }),
                out_file = vim.fn.tempname(),
            }
            -- only a request: the read-only sandbox can still read the whole disk
            local readable = #req.dirs > 0 and ("You may read only these directories:\n- " .. table.concat(req.dirs, "\n- "))
                or "Do not run any commands; answer from the input only."
            return {
                cmd = {
                    "codex", "exec",
                    "-m", req.model,
                    "--sandbox", "read-only",
                    "--ephemeral",
                    "--skip-git-repo-check",
                    -- no user MCP servers or project rules in background runs; login still comes from CODEX_HOME
                    "--ignore-user-config",
                    "-C", config.options.ai.workdir,
                    "--output-schema", state.schema_file,
                    "-o", state.out_file,
                    "-",
                },
                stdin = req.system .. "\n\n" .. readable .. "\n\n" .. req.prompt,
                state = state,
            }
        end,
        parse = function(res, state)
            local ok, data = pcall(function()
                return vim.json.decode(table.concat(vim.fn.readfile(state.out_file), "\n"))
            end)
            vim.fn.delete(state.schema_file)
            vim.fn.delete(state.out_file)
            if not ok or type(data) ~= "table" then
                return nil, "exit " .. res.code .. ": " .. (res.stderr .. res.stdout):sub(-300)
            end
            return { data = data }
        end,
        access = function()
            return "read-only sandbox that CAN READ THE ENTIRE DISK (no deny list; folder limits are only asked for)"
        end,
        budget = function()
            return "no cap (codex has none)"
        end,
    },
}

function M.backend()
    local name = config.options.ai.backend
    local backend = config.options.ai.backends[name] or backends[name] or error("fieldnotes: unknown ai.backend " .. name)
    for _, fn in ipairs({ "prepare", "parse", "access", "budget" }) do
        if type(backend[fn]) ~= "function" then
            error("fieldnotes: ai.backends." .. name .. " needs a " .. fn .. " function")
        end
    end
    return backend
end

function M.models()
    local ai = config.options.ai
    return ai.models[ai.backend] or error("fieldnotes: no ai.models for backend " .. ai.backend)
end

function M.cost_text(cost)
    return cost and string.format(" ($%.3f)", cost) or ""
end

function M.run(file, req, on_done)
    local backend = M.backend()
    vim.fn.mkdir(config.options.ai.workdir, "p")
    local run = backend.prepare(req)
    vim.system(run.cmd, { text = true, stdin = run.stdin, cwd = config.options.ai.workdir }, function(res)
        vim.schedule(function()
            running[file] = nil
            local result, err = backend.parse(res, run.state)
            if not result then
                return vim.notify("fieldnotes: " .. req.model .. " failed: " .. err, vim.log.levels.ERROR)
            end
            on_done(result)
        end)
    end)
    -- set only once the process started, so a failed spawn cannot leave the note locked
    running[file] = true
end

function M.with_instructions(prompt, instructions)
    if instructions == "" then
        return prompt
    end
    return prompt .. "\n\nExtra instructions from the engineer for this run (follow them over the defaults):\n" .. instructions
end

return M
