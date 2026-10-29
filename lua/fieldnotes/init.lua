local config = require("fieldnotes.config")
local notes = require("fieldnotes.notes")
local items = require("fieldnotes.items")
local context = require("fieldnotes.ai.context")
local ticket = require("fieldnotes.ai.ticket")

local M = {}

local commands = {
    new = notes.new,
    daily = notes.daily,
    find = function()
        notes.find(notes.current_project())
    end,
    find_all = function()
        notes.find()
    end,
    open_items = function()
        items.show(config.options.open_items_file, true)
    end,
    closed_items = function()
        items.show(config.options.closed_items_file, true)
    end,
    context = function()
        context.run()
    end,
    ticket = function()
        ticket.run()
    end,
    delete = function()
        local file = vim.api.nvim_buf_get_name(0)
        if not notes.in_vault(file) or items.is_list(file) then
            return vim.notify("fieldnotes: not a vault note", vim.log.levels.WARN)
        end
        local rel = notes.rel(file)
        if vim.fn.confirm("Delete " .. rel .. "?", "&Yes\n&No", 2) == 1 and notes.delete(rel) then
            vim.notify("fieldnotes: " .. rel .. " moved to " .. vim.fs.basename(config.options.deleted_dir))
        end
    end,
}

local global_keys = {
    { "new", "new", "new note" },
    { "daily", "daily", "daily note" },
    { "find_project", "find", "find notes in project" },
    { "find_all", "find_all", "find all notes" },
    { "open_items", "open_items", "open items" },
    { "closed_items", "closed_items", "closed items" },
}

function M.setup(opts)
    config.setup(opts)
    local o = config.options

    for _, k in ipairs(global_keys) do
        local lhs = o.keymaps[k[1]]
        if lhs then
            vim.keymap.set("n", lhs, commands[k[2]], { desc = "Fieldnotes: " .. k[3] })
        end
    end

    vim.api.nvim_create_user_command("Fieldnotes", function(args)
        local fn = commands[args.args]
        if not fn then
            return vim.notify("fieldnotes: unknown command " .. args.args, vim.log.levels.ERROR)
        end
        fn()
    end, {
        nargs = 1,
        complete = function()
            return vim.tbl_keys(commands)
        end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("fieldnotes", { clear = true }),
        pattern = "*.md",
        callback = function(args)
            local file = vim.api.nvim_buf_get_name(args.buf)
            if items.is_list(file) then
                items.attach(args.buf)
            elseif notes.in_vault(file) then
                -- buffer-local so global <leader>a mappings stay instant outside notes
                if o.keymaps.ai_context then
                    vim.keymap.set("n", o.keymaps.ai_context, commands.context, { buffer = args.buf, desc = "Fieldnotes: AI code context" })
                end
                if o.keymaps.ai_ticket then
                    vim.keymap.set("n", o.keymaps.ai_ticket, commands.ticket, { buffer = args.buf, desc = "Fieldnotes: AI ticket draft" })
                end
            end
        end,
    })
end

return M
