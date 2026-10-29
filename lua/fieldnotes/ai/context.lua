local config = require("fieldnotes.config")
local notes = require("fieldnotes.notes")
local runner = require("fieldnotes.ai.runner")
local dialog = require("fieldnotes.ai.dialog")

local M = {}

local SECTION = "## Code context"

local REF = { type = "object", properties = { ref = { type = "string" }, what = { type = "string" } }, required = { "ref", "what" } }

local SCHEMA = {
    type = "object",
    properties = {
        anchors = {
            type = "array",
            items = {
                type = "object",
                properties = { anchor = { type = "string" }, found_in = { type = "array", items = { type = "string" } } },
                required = { "anchor", "found_in" },
            },
        },
        branches_read = { type = "array", items = { type = "string" } },
        data_path = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    role = { type = "string", enum = { "contract", "producer", "consumer", "related" } },
                    ref = { type = "string" },
                    what = { type = "string" },
                },
                required = { "role", "ref", "what" },
            },
        },
        likely_cause = { type = "string" },
        fix_locations = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    ref = { type = "string" },
                    what = { type = "string" },
                    symptom_path = { type = "string", description = "how this location produces the reported symptom" },
                },
                required = { "ref", "what", "symptom_path" },
            },
        },
        tests = { type = "array", items = REF },
        not_found = { type = "array", items = { type = "string" } },
        open_questions = { type = "array", items = { type = "string" } },
    },
    required = { "anchors", "branches_read", "data_path", "likely_cause", "fix_locations", "tests", "not_found", "open_questions" },
}

function M.bounds(lines)
    for i, line in ipairs(lines) do
        if line == SECTION then
            for j = i + 1, #lines do
                if lines[j]:match("^## ") then
                    return i, j - 1
                end
            end
            return i, #lines
        end
    end
end

-- "/abs/file:LINE" or "/abs/file:START-END" shown relative to repos_dir, or nil when the file or line does not exist.
local function check_ref(ref)
    local path, lnum = ref:match("^(/.-):(%d+)%-?%d*$")
    if not path or vim.fn.filereadable(path) == 0 or tonumber(lnum) > #vim.fn.readfile(path) then
        return nil
    end
    local repos_dir = config.options.repos_dir
    return (path:sub(1, #repos_dir + 1) == repos_dir .. "/" and path:sub(#repos_dir + 2) or path) .. ":" .. lnum
end

local function render(data, model, cost, instructions)
    local lines = { SECTION, "" }
    local dropped = 0
    local function block(title, items)
        if #items > 0 then
            vim.list_extend(lines, { "**" .. title .. "**", "" })
            vim.list_extend(lines, items)
            table.insert(lines, "")
        end
    end
    local function refs(title, items, fmt)
        local out = {}
        for _, item in ipairs(items) do
            local ref = check_ref(item.ref)
            if ref then
                table.insert(out, fmt(item, ref))
            else
                dropped = dropped + 1
            end
        end
        block(title, out)
    end
    local function bullets(items)
        return vim.tbl_map(function(item)
            return "- " .. item
        end, items)
    end

    if data.likely_cause ~= "" then
        vim.list_extend(lines, { "**Likely cause:** " .. data.likely_cause, "" })
    end
    refs("Data path", data.data_path, function(item, ref)
        return string.format("- %s `%s` %s", item.role, ref, item.what)
    end)
    refs("Where to fix", data.fix_locations, function(item, ref)
        return string.format("- `%s` %s (symptom path: %s)", ref, item.what, item.symptom_path)
    end)
    refs("Tests", data.tests, function(item, ref)
        return string.format("- `%s` %s", ref, item.what)
    end)
    block("Not found", bullets(data.not_found))
    block("Open questions", bullets(data.open_questions))
    block("Anchors", vim.tbl_map(function(a)
        local repos = vim.tbl_map(vim.fs.basename, a.found_in)
        return string.format("- `%s`: %s", a.anchor, #repos > 0 and table.concat(repos, ", ") or "not found")
    end, data.anchors))
    if #data.branches_read > 0 then
        vim.list_extend(lines, { "**Branches read:** " .. table.concat(data.branches_read, ", "), "" })
    end
    if instructions ~= "" then
        vim.list_extend(lines, { "**Instructions:** " .. instructions:gsub("\n", " "), "" })
    end
    local meta = string.format("_%s, %s", model, os.date("%Y-%m-%d %H:%M"))
    if cost then
        meta = meta .. string.format(", $%.3f", cost)
    end
    if dropped > 0 then
        meta = meta .. string.format(", %d unverifiable ref(s) dropped", dropped)
    end
    table.insert(lines, meta .. "_")
    return lines
end

local function write_section(buf, file, section)
    if not vim.api.nvim_buf_is_loaded(buf) then
        buf = vim.fn.bufadd(file)
        vim.fn.bufload(buf)
    end
    local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local s, e = M.bounds(current)
    if s then
        vim.api.nvim_buf_set_lines(buf, s - 1, e, false, section)
    else
        if current[#current] ~= "" then
            table.insert(section, 1, "")
        end
        vim.api.nvim_buf_set_lines(buf, #current, #current, false, section)
    end
    vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
    end)
end

local function start(buf, file, model, instructions)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local s, e = M.bounds(lines)
    if s then
        lines = vim.list_extend(vim.list_slice(lines, 1, s - 1), vim.list_slice(lines, e + 1))
    end
    local rel = notes.rel(file)
    local dirs = runner.repo_dirs()

    vim.notify(string.format("fieldnotes: %s code context for %s...", model, rel))
    runner.run(file, {
        system = runner.prompt("code_context", { repos = "- " .. table.concat(dirs, "\n- "), context = runner.context_text() }),
        prompt = runner.with_instructions(
            string.format("Project: %s\nNote: %s\n\n%s", notes.project_of(rel), rel, table.concat(lines, "\n")),
            instructions
        ),
        schema = SCHEMA,
        model = model,
        tools = "Read,Grep,Glob",
        dirs = dirs,
    }, function(result)
        write_section(buf, file, render(result.data, model, result.cost, instructions))
        vim.notify("fieldnotes: code context added to " .. rel .. runner.cost_text(result.cost))
    end)
end

function M.run(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local file = runner.check(buf)
    if not file then
        return
    end
    if not config.options.repos_dir or #config.options.ai.repos == 0 then
        return vim.notify("fieldnotes: set repos_dir and ai.repos for code context", vim.log.levels.ERROR)
    end
    local has_section = M.bounds(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) ~= nil
    dialog.open({
        title = "AI code context",
        header = {
            "Note:    " .. notes.rel(file),
            "Repos:   " .. table.concat(vim.tbl_map(vim.fs.basename, runner.repo_dirs()), ", "),
            "Access:  " .. runner.backend().access("Read,Grep,Glob"),
            "Context: " .. (config.options.ai.context_file and vim.fs.basename(config.options.ai.context_file) or "(none)"),
        },
        body = {
            "Will do:",
            "  1. pull exact anchors from the note (errors, fields, endpoints, names)",
            "  2. search them across the repos above",
            "  3. trace contract / producer / consumer for each field or error",
            "  4. list likely cause, where to fix, tests, not found, open questions",
            has_section and "  5. REPLACE the existing '" .. SECTION .. "' section and save the note"
                or "  5. append a '" .. SECTION .. "' section and save the note",
            "",
            "Suggestions: narrow the search (\"only the payments repo\"), name a suspect,",
            "or ask a question (\"why only this field?\").",
        },
        on_submit = function(model, instructions)
            start(buf, file, model, instructions)
        end,
    })
end

return M
