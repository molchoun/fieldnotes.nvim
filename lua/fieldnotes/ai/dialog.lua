local config = require("fieldnotes.config")
local runner = require("fieldnotes.ai.runner")

local M = {}

local MARKER = "----- Custom instructions (optional, leave empty for defaults) -----"

-- spec: { title, header = lines, body = lines, on_submit = function(model, instructions) }
function M.open(spec)
    local ai = config.options.ai
    local models = vim.deepcopy(runner.models())
    local idx = 1
    local function model_lines()
        local shown = {}
        for i, m in ipairs(models) do
            table.insert(shown, i == idx and "[" .. m .. "]" or m)
        end
        return {
            "Model:   " .. table.concat(shown, "  ") .. "   (" .. ai.backend .. ")",
            "Budget:  " .. runner.backend().budget(),
        }
    end

    local lines = { spec.title, "" }
    vim.list_extend(lines, spec.header)
    local model_row = #lines
    vim.list_extend(lines, model_lines())
    table.insert(lines, "")
    vim.list_extend(lines, spec.body)
    vim.list_extend(lines, { "", "<CR> run   <Tab> next model   m type a model   q / <Esc> cancel   (normal mode)", "", MARKER, "" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    local width = math.min(90, vim.o.columns - 4)
    local height = math.min(#lines + 6, vim.o.lines - 4)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        border = "rounded",
        title = " fieldnotes ",
    })
    vim.api.nvim_win_set_cursor(win, { #lines, 0 })
    vim.cmd.startinsert()

    local function redraw()
        vim.api.nvim_buf_set_lines(buf, model_row, model_row + 2, false, model_lines())
    end
    local function close()
        vim.cmd.stopinsert()
        vim.api.nvim_win_close(win, true)
    end
    local function submit()
        local instructions, after = {}, false
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            if after then
                table.insert(instructions, line)
            elseif line == MARKER then
                after = true
            end
        end
        close()
        spec.on_submit(models[idx], vim.trim(table.concat(instructions, "\n")))
    end
    vim.keymap.set({ "n", "i" }, "<Tab>", function()
        idx = idx % #models + 1
        redraw()
    end, { buffer = buf })
    vim.keymap.set("n", "m", function()
        vim.ui.input({ prompt = "Model (" .. ai.backend .. "): " }, function(name)
            if name and name ~= "" then
                table.insert(models, name)
                idx = #models
                redraw()
            end
        end)
    end, { buffer = buf })
    vim.keymap.set("n", "<CR>", submit, { buffer = buf })
    vim.keymap.set("n", "q", close, { buffer = buf })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf })
end

return M
