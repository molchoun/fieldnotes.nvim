local config = require("fieldnotes.config")
local notes = require("fieldnotes.notes")
local runner = require("fieldnotes.ai.runner")
local dialog = require("fieldnotes.ai.dialog")
local context = require("fieldnotes.ai.context")

local M = {}

local SCHEMA = {
    type = "object",
    properties = { title = { type = "string" }, markdown = { type = "string" } },
    required = { "title", "markdown" },
}

local function out_path(file)
    return config.options.ai.ticket.out_dir .. "/" .. vim.fn.fnamemodify(file, ":t:r") .. ".md"
end

local function rules_text()
    local file = config.options.ai.ticket.rules_file
    return file and runner.read(file, "ai.ticket.rules_file") or "(none, use a clear Jira-style structure)"
end

local function start(buf, file, model, instructions)
    local rel = notes.rel(file)
    local out = out_path(file)

    vim.notify(string.format("fieldnotes: %s ticket for %s...", model, rel))
    runner.run(file, {
        system = runner.prompt("ticket", { rules = rules_text(), context = runner.context_text() }),
        prompt = runner.with_instructions(
            string.format("Project: %s\nNote: %s\n\n%s", notes.project_of(rel), rel, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")),
            instructions
        ),
        schema = SCHEMA,
        model = model,
        tools = "",
        dirs = {},
    }, function(result)
        vim.fn.mkdir(vim.fs.dirname(out), "p")
        local lines = { "# " .. result.data.title, "" }
        vim.list_extend(lines, vim.split(vim.trim(result.data.markdown), "\n", { plain = true }))
        vim.fn.writefile(lines, out)
        vim.notify("fieldnotes: ticket written to " .. vim.fn.fnamemodify(out, ":~") .. runner.cost_text(result.cost))
    end)
end

function M.run(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local file = runner.check(buf)
    if not file then
        return
    end
    if not config.options.ai.ticket.out_dir then
        return vim.notify("fieldnotes: set ai.ticket.out_dir for tickets", vim.log.levels.ERROR)
    end
    local out = out_path(file)
    local has_context = context.bounds(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) ~= nil
    local rules = config.options.ai.ticket.rules_file
    dialog.open({
        title = "AI ticket draft",
        header = {
            "Note:    " .. notes.rel(file),
            "Output:  " .. vim.fn.fnamemodify(out, ":~"),
            "Rules:   " .. (rules and vim.fn.fnamemodify(rules, ":~") or "(none)"),
            "Access:  " .. runner.backend().access(""),
        },
        body = {
            "Will do:",
            has_context and "  1. read the note, including its '## Code context' section"
                or "  1. read the note (no '## Code context' yet; run code context first for richer facts)",
            "  2. write the ticket per the rules, turning file paths into names",
            vim.fn.filereadable(out) == 1 and "  3. REPLACE the existing ticket file (your edits there will be lost)"
                or "  3. create the ticket file",
            "",
            "Suggestions: set the type (\"Bug\"), scope it (\"only the API part\"),",
            "or add facts the note lacks (\"tenant X, UAT, claim 4013\").",
        },
        on_submit = function(model, instructions)
            start(buf, file, model, instructions)
        end,
    })
end

return M
