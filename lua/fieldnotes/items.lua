local config = require("fieldnotes.config")
local notes = require("fieldnotes.notes")
local context = require("fieldnotes.ai.context")
local ticket = require("fieldnotes.ai.ticket")

local M = {}

local history = {}
-- nil until first scan, so a list opened via :e or find still gets its TODO sections
local todos
local yank_ns = vim.api.nvim_create_namespace("fieldnotes_yank")

-- rg exits 1 for "no matches" and 2 for errors, but on 2 still prints what it could read
-- (e.g. one root-owned folder in a repo), so keep the results and warn
local function rg(args)
    local res = vim.system(vim.list_extend({ "rg" }, args), { text = true }):wait()
    if res.code > 1 then
        vim.notify("fieldnotes: " .. vim.split(res.stderr, "\n")[1], vim.log.levels.WARN)
    end
    return vim.split(res.stdout, "\n", { trimempty = true })
end

local function code_todos(project)
    local repo = config.options.repos_dir and (config.options.repos_dir .. "/" .. project)
    if not config.options.todo_pattern or not repo or vim.fn.isdirectory(repo) == 0 then
        return {}
    end
    local hits = {}
    for _, hit in ipairs(rg({ "-n", "--no-heading", config.options.todo_pattern, repo })) do
        local path, lnum, text = hit:match("^(.-):(%d+):(.*)$")
        table.insert(hits, { path = path:sub(#repo + 2), lnum = tonumber(lnum), text = vim.trim(text:match("(TODO.*)$") or text) })
    end
    table.sort(hits, function(a, b)
        if a.path == b.path then
            return a.lnum < b.lnum
        end
        return a.path < b.path
    end)
    return vim.tbl_map(function(h)
        return string.format("- `%s:%d` %s", h.path, h.lnum, h.text)
    end, hits)
end

local function render(lines, title, mark, groups, with_todos)
    local projects = vim.tbl_keys(groups)
    table.sort(projects)
    local total = 0
    for _, project in ipairs(projects) do
        total = total + #groups[project]
    end
    table.insert(lines, string.format("# %s (%d)", title, total))
    for _, project in ipairs(projects) do
        local items = groups[project]
        table.sort(items, function(a, b)
            if a.age == b.age then
                return a.rel < b.rel
            end
            return (a.age or -1) > (b.age or -1)
        end)
        vim.list_extend(lines, { "", string.format("## %s (%d)", project, #items) })
        if #items > 0 then
            table.insert(lines, "")
        end
        for _, item in ipairs(items) do
            local age = item.age and string.format(" (%dd)", item.age) or ""
            table.insert(lines, string.format("- [%s] %s%s ([[%s]])", mark, vim.fs.basename(item.rel), age, item.rel))
        end
        local project_todos = with_todos and todos[project] or {}
        if #project_todos > 0 then
            vim.list_extend(lines, { "", string.format("### TODO (%d)", #project_todos), "" })
            vim.list_extend(lines, project_todos)
        end
    end
end

-- Rebuilds both lists from the vault and opens `file`. TODOs are rescanned and old deleted
-- notes purged only when asked (list opened), so x / u / a / D stay fast on big repos.
function M.show(file, rescan)
    if rescan then
        notes.purge_deleted()
    end
    local open, closed = {}, {}
    local deleted = config.options.deleted_dir:sub(#config.options.notes_dir + 2)
    for _, f in ipairs(rg({ "-l", "--glob", "*.md", "--glob", "!" .. deleted .. "/**", "^done: (true|false)$", config.options.notes_dir })) do
        local rel = notes.rel(f)
        local project = notes.project_of(rel)
        local done, age = notes.meta(f)
        local groups = done == "true" and closed or open
        groups[project] = groups[project] or {}
        table.insert(groups[project], { rel = rel, age = age })
    end

    if rescan or not todos then
        todos = {}
        for project in pairs(vim.tbl_extend("keep", {}, open, closed)) do
            todos[project] = code_todos(project)
        end
    end
    for project, list in pairs(todos) do
        if #list > 0 then
            open[project] = open[project] or {}
        end
    end

    local open_lines, closed_lines = {}, {}
    render(open_lines, "Open Items", " ", open, true)
    render(closed_lines, "Closed Items", "x", closed, false)
    vim.fn.writefile(open_lines, config.options.open_items_file)
    vim.fn.writefile(closed_lines, config.options.closed_items_file)
    vim.cmd("edit! " .. vim.fn.fnameescape(file))
end

function M.is_list(file)
    return file == config.options.open_items_file or file == config.options.closed_items_file
end

local function item_at(lnum)
    local line = vim.fn.getline(lnum)
    return line:match("%[%[(.-)%]%]"), line:match("^%- %[x%]") ~= nil
end

local function todo_at(lnum)
    local path, line_nr, text = vim.fn.getline(lnum):match("^%- `(.-):(%d+)` (.*)$")
    if not path then
        return nil
    end
    for i = lnum, 1, -1 do
        local project = vim.fn.getline(i):match("^## (.-) %(%d+%)$")
        if project then
            return { file = config.options.repos_dir .. "/" .. project .. "/" .. path, path = path, lnum = tonumber(line_nr), text = text }
        end
    end
end

local function yank(first, last)
    local chunks = {}
    for lnum = first, last do
        local rel = item_at(lnum)
        local todo = todo_at(lnum)
        if rel then
            table.insert(chunks, notes.body(rel))
        elseif todo then
            table.insert(chunks, string.format("%s:%d %s", todo.path, todo.lnum, todo.text))
        end
    end
    if #chunks == 0 then
        return
    end
    local text = table.concat(chunks, "\n\n")
    vim.fn.setreg("+", text)
    vim.fn.setreg('"', text)
    vim.hl.range(0, yank_ns, "IncSearch", { first - 1, 0 }, { last - 1, -1 }, { regtype = "V", timeout = 150 })
    vim.notify(string.format("fieldnotes: yanked %d item(s)", #chunks))
end

local function add(file)
    local header = vim.fn.search("^## ", "bnW")
    local default = header > 0 and vim.fn.getline(header):match("^## (.-) %(%d+%)$") or notes.current_project()
    vim.ui.input({ prompt = "Title: " }, function(title)
        if not title or title == "" then
            return
        end
        vim.ui.input({ prompt = "Project: ", default = default }, function(project)
            if not project or project == "" then
                return
            end
            local rel = project .. "/" .. title
            if vim.fn.filereadable(notes.path(rel)) == 1 then
                return vim.notify("fieldnotes: " .. rel .. " already exists", vim.log.levels.ERROR)
            end
            notes.create(project, title)
            M.show(file)
            vim.fn.search("\\V[[" .. rel .. "]]", "w")
        end)
    end)
end

local function help(file)
    local km = config.options.keymaps
    local is_open = file == config.options.open_items_file
    local keys = {
        "<CR>  open note / jump to TODO",
        "y     yank content (visual: all selected)",
        is_open and "x     close item" or "x     reopen item",
    }
    if is_open then
        table.insert(keys, "a     add item")
    end
    table.insert(keys, "u     undo last x")
    if km.delete then
        table.insert(keys, km.delete .. "     delete note (to " .. vim.fs.basename(config.options.deleted_dir) .. ")")
    end
    if km.ai_context then
        table.insert(keys, km.ai_context .. "  AI code context for item")
    end
    if km.ai_ticket then
        table.insert(keys, km.ai_ticket .. "  AI ticket draft for item")
    end
    table.insert(keys, "?     this help")
    vim.lsp.util.open_floating_preview(keys, "text", { border = "rounded", title = " fieldnotes " })
end

local function set_done(rel, from, to)
    if notes.set_done(rel, from, to) then
        return true
    end
    vim.notify("fieldnotes: no 'done: " .. from .. "' line in " .. rel, vim.log.levels.WARN)
    return false
end

-- Buffer-local keys for an Open/Closed Items buffer.
function M.attach(buf)
    local file = vim.api.nvim_buf_get_name(buf)
    local km = config.options.keymaps
    vim.bo[buf].modifiable = false
    local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = "Fieldnotes: " .. desc })
    end
    local function on_item(action)
        return function()
            local rel = item_at(vim.fn.line("."))
            if not rel then
                return vim.notify("fieldnotes: no note on this line", vim.log.levels.WARN)
            end
            local note = vim.fn.bufadd(notes.path(rel))
            vim.fn.bufload(note)
            action(note)
        end
    end

    map("n", "<CR>", function()
        local rel = item_at(vim.fn.line("."))
        local todo = todo_at(vim.fn.line("."))
        if rel then
            vim.cmd.edit(vim.fn.fnameescape(notes.path(rel)))
        elseif todo then
            vim.cmd.edit(vim.fn.fnameescape(todo.file))
            vim.api.nvim_win_set_cursor(0, { todo.lnum, 0 })
        end
    end, "open item")
    map("n", "x", function()
        local rel, closed = item_at(vim.fn.line("."))
        if not rel then
            return
        end
        local from, to = tostring(closed), tostring(not closed)
        if not set_done(rel, from, to) then
            return
        end
        table.insert(history, { rel = rel, from = from, to = to })
        local row = vim.api.nvim_win_get_cursor(0)[1]
        M.show(file)
        vim.api.nvim_win_set_cursor(0, { math.min(row, vim.api.nvim_buf_line_count(0)), 0 })
    end, "toggle done")
    map("n", "u", function()
        local last = table.remove(history)
        if not last then
            return vim.notify("fieldnotes: nothing to undo")
        end
        if set_done(last.rel, last.to, last.from) then
            M.show(file)
            vim.fn.search("\\V[[" .. last.rel .. "]]", "w")
        end
    end, "undo last toggle")
    if km.delete then
        map("n", km.delete, function()
            local rel = item_at(vim.fn.line("."))
            if not rel then
                return
            end
            local days = config.options.deleted_retention_days
            if vim.fn.confirm("Delete " .. rel .. "? (kept " .. days .. " days in " .. vim.fs.basename(config.options.deleted_dir) .. ")", "&Yes\n&No", 2) ~= 1 then
                return
            end
            if notes.delete(rel) then
                local row = vim.api.nvim_win_get_cursor(0)[1]
                M.show(file)
                vim.api.nvim_win_set_cursor(0, { math.min(row, vim.api.nvim_buf_line_count(0)), 0 })
            end
        end, "delete note")
    end
    map("n", "y", function()
        yank(vim.fn.line("."), vim.fn.line("."))
    end, "yank item")
    map("x", "y", function()
        local first, last = vim.fn.line("v"), vim.fn.line(".")
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        yank(math.min(first, last), math.max(first, last))
    end, "yank selected items")
    if file == config.options.open_items_file then
        map("n", "a", function()
            add(file)
        end, "add item")
    end
    map("n", "?", function()
        help(file)
    end, "help")
    if km.ai_context then
        map("n", km.ai_context, on_item(context.run), "AI code context for item")
    end
    if km.ai_ticket then
        map("n", km.ai_ticket, on_item(ticket.run), "AI ticket draft for item")
    end
end

return M
