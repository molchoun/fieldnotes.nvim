local M = {}

local function default_template(ctx)
    local done = ctx.daily and "" or "done: false\n"
    return string.format("---\ntitle: %s\nproject: %s\ndate: %s\n%stags: []\n---\n\n# %s\n", ctx.title, ctx.project, ctx.date, done, ctx.title)
end

M.defaults = {
    notes_dir = "~/notes",
    -- folder per project under notes_dir; also where TODO scan and AI look for code: <repos_dir>/<project>
    repos_dir = nil,
    root_markers = { ".git", ".hg", "package.json", "Cargo.toml", "go.mod", "mix.exs", "pyproject.toml", "setup.py", "Makefile" },
    template = default_template,
    open_items_file = "Open Items.md",
    closed_items_file = "Closed Items.md",
    -- rg pattern for the per-project TODO sections; false turns them off
    todo_pattern = "\\bTODO\\b",
    deleted_dir = "Deleted Notes",
    -- deleted notes older than this are removed for good when a list opens
    deleted_retention_days = 30,
    keymaps = {
        new = "<leader>no",
        daily = "<leader>nt",
        find_project = "<leader>np",
        find_all = "<leader>na",
        open_items = "<leader>nO",
        closed_items = "<leader>nC",
        -- in item lists only
        delete = "D",
        -- buffer-local in notes and item lists only
        ai_context = "<leader>ai",
        ai_ticket = "<leader>at",
    },
    ai = {
        -- "claude", "codex" or a name from ai.backends
        backend = "claude",
        -- your own backends: { name = { prepare, parse, access, budget } }, see README
        backends = {},
        -- models offered in the dialog per backend, first is the default; any other name can be typed there
        models = {
            claude = { "haiku", "sonnet", "opus" },
            codex = { "gpt-5.4-mini", "gpt-5.4" },
        },
        -- per run, claude only
        budget_usd = 2,
        -- repo folder names under repos_dir the AI may read
        repos = {},
        -- shared knowledge appended to every prompt
        context_file = nil,
        -- override plugin prompts: { code_context = "/path.md", ticket = "/path.md" }
        prompts = {},
        ticket = { rules_file = nil, out_dir = nil },
        deny = {
            "Read(//**/.env)",
            "Read(//**/.env.*)",
            "Read(//**/*.env)",
            "Read(//**/secrets/**)",
            "Read(//**/*wg*.conf)",
            "Read(//**/application*.yml)",
            "Read(//**/application*.yaml)",
            "Read(//**/parameters*.yaml)",
            "Read(//**/*.pem)",
            "Read(//**/*.key)",
            "Read(//**/*.p12)",
            "Read(//**/*.pfx)",
            "Read(//**/*.jks)",
            "Read(//**/id_rsa*)",
            "Read(//**/*.gpg)",
        },
        workdir = vim.fn.stdpath("cache") .. "/fieldnotes",
    },
}

M.options = vim.deepcopy(M.defaults)

local function expand(path)
    return path and vim.fs.normalize(vim.fn.expand(path)) or nil
end

function M.setup(opts)
    local o = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    -- lists replace, never merge index-wise
    for _, key in ipairs({ "root_markers" }) do
        if opts and opts[key] then
            o[key] = opts[key]
        end
    end
    for _, key in ipairs({ "repos", "deny" }) do
        if opts and opts.ai and opts.ai[key] then
            o.ai[key] = opts.ai[key]
        end
    end
    for backend, list in pairs(opts and opts.ai and opts.ai.models or {}) do
        o.ai.models[backend] = list
    end
    o.notes_dir = expand(o.notes_dir)
    o.repos_dir = expand(o.repos_dir)
    o.open_items_file = o.notes_dir .. "/" .. o.open_items_file
    o.closed_items_file = o.notes_dir .. "/" .. o.closed_items_file
    o.deleted_dir = o.notes_dir .. "/" .. o.deleted_dir
    o.ai.context_file = expand(o.ai.context_file)
    o.ai.ticket.rules_file = expand(o.ai.ticket.rules_file)
    o.ai.ticket.out_dir = expand(o.ai.ticket.out_dir)
    for name, path in pairs(o.ai.prompts) do
        o.ai.prompts[name] = expand(path)
    end
    M.options = o
end

return M
