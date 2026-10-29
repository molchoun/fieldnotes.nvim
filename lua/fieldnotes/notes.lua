local config = require("fieldnotes.config")

local M = {}

-- deleted notes are outside the vault for every feature
function M.in_vault(file)
    local deleted = config.options.deleted_dir .. "/"
    return file:sub(1, #config.options.notes_dir + 1) == config.options.notes_dir .. "/" and file:sub(1, #deleted) ~= deleted
end

-- vault-relative path without extension, e.g. "my-repo/some note"
function M.rel(file)
    return (file:sub(#config.options.notes_dir + 2):gsub("%.md$", ""))
end

function M.path(rel)
    return config.options.notes_dir .. "/" .. rel .. ".md"
end

function M.project_of(rel)
    return rel:match("^([^/]+)/") or "root"
end

function M.current_project()
    local name = vim.api.nvim_buf_get_name(0)
    local start = (name ~= "" and vim.fn.filereadable(name) == 1) and name or vim.fn.getcwd()
    return vim.fs.basename(vim.fs.root(start, config.options.root_markers) or vim.fn.getcwd())
end

-- Writes the note from the template unless it exists. Returns its path.
function M.create(project, title, daily)
    local path = daily and (config.options.notes_dir .. "/daily/" .. title .. ".md") or M.path(project .. "/" .. title)
    if vim.fn.filereadable(path) == 0 then
        local content = config.options.template({ title = title, project = project, date = os.date("%Y-%m-%d"), daily = daily })
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
    end
    return path
end

function M.new()
    local project = M.current_project()
    vim.ui.input({ prompt = "Note title (" .. project .. "): " }, function(title)
        if title and title ~= "" then
            vim.cmd.edit(vim.fn.fnameescape(M.create(project, title)))
        end
    end)
end

function M.daily()
    vim.cmd.edit(vim.fn.fnameescape(M.create(M.current_project(), os.date("%Y-%m-%d"), true)))
end

function M.find(project)
    local dir = project and (config.options.notes_dir .. "/" .. project) or config.options.notes_dir
    local files = vim.tbl_filter(M.in_vault, vim.fn.globpath(dir, "**/*.md", false, true))
    if #files == 0 then
        return vim.notify("fieldnotes: no notes in " .. vim.fn.fnamemodify(dir, ":~"), vim.log.levels.WARN)
    end
    table.sort(files)
    vim.ui.select(files, {
        prompt = "Notes" .. (project and (" (" .. project .. ")") or "") .. ": ",
        format_item = M.rel,
    }, function(file)
        if file then
            vim.cmd.edit(vim.fn.fnameescape(file))
        end
    end)
end

-- done ("true"/"false"/nil) and age in days from the frontmatter
function M.meta(file)
    local done, age
    for _, line in ipairs(vim.fn.readfile(file, "", 10)) do
        done = done or line:match("^done: (%a+)$")
        local y, m, d = line:match("^date: (%d+)-(%d+)-(%d+)$")
        if y then
            local now = os.date("*t")
            -- noon on both sides keeps DST shifts out of the day count
            local today = os.time({ year = now.year, month = now.month, day = now.day, hour = 12 })
            local created = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
            age = math.floor((today - created) / 86400 + 0.5)
        end
    end
    return done, age
end

function M.set_done(rel, from, to)
    local file = M.path(rel)
    local lines = vim.fn.readfile(file)
    for i, line in ipairs(lines) do
        if line == "done: " .. from then
            lines[i] = "done: " .. to
            vim.fn.writefile(lines, file)
            return true
        end
    end
    return false
end

-- Moves the note to deleted_dir, keeping its project folder. Refuses when its buffer has unsaved edits.
function M.delete(rel)
    local src = M.path(rel)
    local buf = vim.fn.bufnr(src)
    if buf ~= -1 and vim.bo[buf].modified then
        vim.notify("fieldnotes: " .. rel .. " has unsaved changes, not deleted", vim.log.levels.WARN)
        return false
    end
    local dst = config.options.deleted_dir .. "/" .. rel .. ".md"
    if vim.fn.filereadable(dst) == 1 then
        dst = config.options.deleted_dir .. "/" .. rel .. " " .. os.date("%Y%m%d-%H%M%S") .. ".md"
    end
    vim.fn.mkdir(vim.fs.dirname(dst), "p")
    assert(vim.uv.fs_rename(src, dst))
    -- mtime marks the deletion time for retention
    local now = os.time()
    vim.uv.fs_utime(dst, now, now)
    if buf ~= -1 then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
    return true
end

function M.purge_deleted()
    local cutoff = os.time() - config.options.deleted_retention_days * 86400
    for _, f in ipairs(vim.fn.globpath(config.options.deleted_dir, "**/*.md", false, true)) do
        if vim.uv.fs_stat(f).mtime.sec < cutoff then
            assert(os.remove(f))
        end
    end
end

function M.body(rel)
    local lines = vim.fn.readfile(M.path(rel))
    if lines[1] == "---" then
        for i = 2, #lines do
            if lines[i] == "---" then
                lines = vim.list_slice(lines, i + 1)
                break
            end
        end
    end
    return vim.trim(table.concat(lines, "\n"))
end

return M
