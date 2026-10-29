# fieldnotes.nvim

Combination of notetaker and todoist in nvim.

Task notes per project in a markdown vault (works with Obsidian), an open/closed items view across all projects with code TODOs, and on-demand AI help: code context traced across your repos and ticket drafts.

Requires Neovim 0.11+, `rg`, and for AI features the `claude` CLI.

## Setup (lazy.nvim)

```lua
{
    dir = "~/workspace/personal/fieldnotes.nvim",
    lazy = false,
    opts = {
        notes_dir = "~/notes",
        repos_dir = "~/code",                  -- project "foo" lives in ~/code/foo
        ai = {
            repos = { "foo", "bar" },          -- folders under repos_dir the AI may read
            context_file = "~/notes/AI Context.md",
            ticket = { rules_file = "~/notes/ticket-rules.md", out_dir = "~/tickets" },
        },
    },
}
```

All options and defaults: `lua/fieldnotes/config.lua`.

## Notes

A note lives at `<notes_dir>/<project>/<title>.md`. The project is the folder name of the nearest root marker (`.git`, `pyproject.toml`, ...) above the current file, or the cwd. New notes get frontmatter with `done: false`; daily notes do not.

| Key | Action |
|---|---|
| `<leader>no` | new note in the current project |
| `<leader>nt` | daily note |
| `<leader>np` / `<leader>na` | find notes in project / everywhere (`vim.ui.select`) |
| `<leader>nO` / `<leader>nC` | open items / closed items |

`:Fieldnotes <new|daily|find|find_all|open_items|closed_items|context|ticket|delete>` does the same.

## Items

Open Items lists every note with `done: false`, grouped by project, oldest first, plus a `### TODO` section per project from `rg` over `<repos_dir>/<project>`. Closed Items lists `done: true`. Both are read-only and rebuilt on every action.

| Key | Action |
|---|---|
| `<CR>` | open note, or jump to the TODO line |
| `x` | close (Open) / reopen (Closed) |
| `u` | undo last `x` |
| `a` | add a note (Open only) |
| `y` | yank note content without frontmatter; visual mode yanks all selected |
| `D` | delete note (confirm) |
| `?` | key help |

TODO sections are on by default; set `todo_pattern = false` to turn them off, or change the `rg` pattern.

### Deleting

`D` on an item, or `:Fieldnotes delete` in a note, moves it to `<notes_dir>/Deleted Notes/<project>/` (`deleted_dir`). Deleted notes are left out of the lists, find and AI. They are removed for good `deleted_retention_days` (default 30) after deletion, checked whenever a list opens. To restore, move the file back.

## AI

`<leader>ai` (code context) and `<leader>at` (ticket) work in a note or on an item line. A dialog shows what will run. In normal mode: `<Tab>` cycles the backend's models (`ai.models`, first is the default), `m` types any other model name, `<CR>` runs. Optional instructions go below the marker. Runs are async; a model that does not exist fails with the backend's error.

- **Code context** reads the repos in `ai.repos`, traces contract / producer / consumer, and writes a `## Code context` section into the note. Refs must be `/abs/path:LINE` or `/abs/path:START-END` inside the file; anything else is dropped.
- **Ticket** uses no tools. It writes from the note (including its code context) per `ai.ticket.rules_file` into `ai.ticket.out_dir/<note>.md`.

### Prompts

Bundled in `prompts/`. Override any of them:

```lua
ai = { prompts = { code_context = "~/notes/prompts/code_context.md" } }
```

Placeholders: `{{repos}}` and `{{context}}` (code context), `{{rules}}` and `{{context}}` (ticket). Put domain knowledge (systems, naming, how they connect) in `ai.context_file`, not in the prompts.

### Backends

Set `ai.backend` to `claude` (default) or `codex`. Each lives in the `backends` table in `lua/fieldnotes/ai/runner.lua`: it builds the command and parses the structured result.

| | claude | codex |
|---|---|---|
| Read access | Read/Grep/Glob tools only, `ai.deny` blocks secrets | read-only sandbox that **can read the entire disk**; the repo limit is only a request in the prompt, no deny list |
| Ticket (no tools) | enforced | prompt-level only |
| Budget cap | `ai.budget_usd` per run | none |
| Cost shown | yes | no |

Prefer `claude` for code context on repos that hold secrets.

### Your own backend

Add it under `ai.backends` and select it with `ai.backend`. It needs four functions:

| Function | Gets | Returns |
|---|---|---|
| `prepare(req)` | `{ system, prompt, schema, model, tools, dirs }` | `{ cmd = argv list, stdin = string, state = any }` |
| `parse(res, state)` | `vim.system` result `{ code, stdout, stderr }` and your `state` | `{ data = table, cost = number|nil }`, or `nil, error` |
| `access(tools)` | `"Read,Grep,Glob"` for code context, `""` for tickets | dialog text: what the backend can read |
| `budget()` | | dialog text: spend limit |

`data` must match `req.schema`. `tools == ""` means the run must not read anything. `dirs` are the repos code context may read; a backend without file access can still draft tickets, but its code context will have nothing to search.

Example, a local model through `ollama` (tickets only):

```lua
ai = {
    backend = "ollama",
    models = { ollama = { "qwen3:14b" } },
    backends = {
        ollama = {
            prepare = function(req)
                return {
                    cmd = { "ollama", "run", req.model, "--format", "json" },
                    stdin = req.system .. "\n\nReply with JSON matching this schema:\n" .. vim.json.encode(req.schema) .. "\n\n" .. req.prompt,
                }
            end,
            parse = function(res)
                local ok, data = pcall(vim.json.decode, res.stdout)
                if not ok then
                    return nil, "exit " .. res.code .. ": " .. res.stderr
                end
                return { data = data }
            end,
            access = function()
                return "no tools, local model"
            end,
            budget = function()
                return "free, local"
            end,
        },
    },
}
```
