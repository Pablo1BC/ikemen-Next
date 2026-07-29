local pagedSelect = {
    enabled = false,
    totalPages = 1,
    currentPage = 1,
    cursorSaved = {},
    initialized = false,
    config = {
        pagenavUp = {},
        pagenavDown = {},
        showPageNumber = true,
        pageIndicatorPos = {160, 220},
        pageIndicatorFont = nil,
        pageIndicatorText = "Pagina %d/%d",
    },
}

local function trim(s)
    return s:match('^%s*(.-)%s*$')
end

local function parseSelectDef()
    local f, err = io.open('data/select.def', 'r')
    if not f then return end
    local inSection = false
    for line in f:lines() do
        local trimmed = trim(line)
        if trimmed:lower():match('^%[pagedselect%]$') then
            inSection = true
        elseif trimmed:match('^%[') then
            inSection = false
        elseif inSection then
            local key, value = trimmed:match('^(.+)=(.+)$')
            if key and value then
                key = trim(key):lower()
                value = trim(value)
                if key == 'enabled' then
                    pagedSelect.enabled = tonumber(value) == 1
                elseif key == 'pagenav.up' then
                    pagedSelect.config.pagenavUp = main.f_strsplit(' ', value)
                elseif key == 'pagenav.down' then
                    pagedSelect.config.pagenavDown = main.f_strsplit(' ', value)
                elseif key == 'showpagenumber' then
                    pagedSelect.config.showPageNumber = tonumber(value) ~= 0
                elseif key == 'pageindicator.pos' then
                    local x, y = value:match('^%s*(.-)%s*,%s*(.-)%s*$')
                    if x and y then
                        pagedSelect.config.pageIndicatorPos = {tonumber(x) or 160, tonumber(y) or 220}
                    end
                elseif key == 'pageindicator.font' then
                    pagedSelect.config.pageIndicatorFont = value
                elseif key == 'pageindicator.text' then
                    pagedSelect.config.pageIndicatorText = value:gsub('^\"(.*)\"$', '%1'):gsub("^'(.*)'$", '%1')
                end
            end
        end
    end
    f:close()
end

local function mapCell(cell)
    local rows = motif.select_info.rows
    local cols = motif.select_info.columns
    if not rows or not cols then return cell end
    local cellsPerGrid = rows * cols
    if cell < 1 or cell > cellsPerGrid then return cell end
    return (pagedSelect.currentPage - 1) * cellsPerGrid + cell
end

local origFSelGrid = start.f_selGrid
start.f_selGrid = function(cell, slot)
    if not pagedSelect.enabled then
        return origFSelGrid(cell, slot)
    end
    return origFSelGrid(mapCell(cell), slot)
end

local function rebuildGrid(pageIdx)
    local rows = motif.select_info.rows
    local cols = motif.select_info.columns
    if not rows or not cols then return end
    local cellsPerGrid = rows * cols
    local offset = (pageIdx - 1) * cellsPerGrid
    for r = 1, rows do
        for c = 1, cols do
            local cellIndex = (r - 1) * cols + c
            local actualCell = offset + cellIndex
            local cell = start.t_grid[r][c]
            local charData = origFSelGrid(actualCell)
            if charData and charData.char then
                cell.char = charData.char
                cell.char_ref = charData.char_ref
                cell.hidden = charData.hidden
            else
                cell.char = nil
                cell.char_ref = nil
                cell.hidden = nil
            end
        end
    end
end

local function navigatePage(delta, side, curX, curY)
    local newPage = pagedSelect.currentPage + delta
    if newPage < 1 or newPage > pagedSelect.totalPages then
        if not motif.select_info.wrapping then return false, curX, curY end
        if newPage < 1 then newPage = pagedSelect.totalPages
        else newPage = 1 end
    end
    if pagedSelect.cursorSaved[side] == nil then
        pagedSelect.cursorSaved[side] = {}
    end
    pagedSelect.cursorSaved[side][pagedSelect.currentPage] = {x = curX, y = curY}
    pagedSelect.currentPage = newPage
    rebuildGrid(pagedSelect.currentPage)
    start.needUpdateDrawList = true
    local saved = pagedSelect.cursorSaved[side] and pagedSelect.cursorSaved[side][pagedSelect.currentPage]
    local newX, newY
    if saved then
        newX, newY = saved.x, saved.y
    else
        newX, newY = 0, 0
    end
    return true, newX, newY
end

local origCellMovement = start.f_cellMovement
start.f_cellMovement = function(selX, selY, cmd, side, snd, dir)
    if not pagedSelect.enabled then
        return origCellMovement(selX, selY, cmd, side, snd, dir)
    end
    local rows = motif.select_info.rows
    local upKey = motif.select_info.cell.up.key
    local downKey = motif.select_info.cell.down.key

    if #pagedSelect.config.pagenavUp > 0 then
        if getInput(cmd, pagedSelect.config.pagenavUp) then
            local ok, nx, ny = navigatePage(-1, side, selX, selY)
            if ok then sndPlay(motif.Snd, snd[1], snd[2]); return nx, ny end
        end
    end
    if #pagedSelect.config.pagenavDown > 0 then
        if getInput(cmd, pagedSelect.config.pagenavDown) then
            local ok, nx, ny = navigatePage(1, side, selX, selY)
            if ok then sndPlay(motif.Snd, snd[1], snd[2]); return nx, ny end
        end
    end

    if selY == 0 then
        local inputUp = getInput(cmd, upKey) or dir == 'U'
        if inputUp then
            local ok, nx, ny = navigatePage(-1, side, selX, selY)
            if ok then
                sndPlay(motif.Snd, snd[1], snd[2])
                return nx, ny
            end
            if motif.select_info.wrapping or dir ~= nil then
                local foundY = rows - 1
                for i = rows, 1, -1 do
                    local cell = start.t_grid[i][selX + 1]
                    if cell.char ~= nil and cell.skip ~= 1 and cell.hidden ~= 2 then
                        foundY = i - 1
                        break
                    end
                end
                sndPlay(motif.Snd, snd[1], snd[2])
                return selX, foundY
            end
            return selX, selY
        end
    end

    if selY >= rows - 1 then
        local inputDown = getInput(cmd, downKey) or dir == 'D'
        if inputDown then
            local ok, nx, ny = navigatePage(1, side, selX, selY)
            if ok then
                sndPlay(motif.Snd, snd[1], snd[2])
                return nx, ny
            end
            if motif.select_info.wrapping or dir ~= nil then
                local foundY = 0
                for i = 1, rows do
                    local cell = start.t_grid[i][selX + 1]
                    if cell.char ~= nil and cell.skip ~= 1 and cell.hidden ~= 2 then
                        foundY = i - 1
                        break
                    end
                end
                sndPlay(motif.Snd, snd[1], snd[2])
                return selX, foundY
            end
            return selX, selY
        end
    end

    return origCellMovement(selX, selY, cmd, side, snd, dir)
end

local origSelectReset = start.f_selectReset
start.f_selectReset = function(hardReset, preserveProgress)
    origSelectReset(hardReset, preserveProgress)
    if not pagedSelect.initialized then
        pagedSelect.initialized = true
        parseSelectDef()
        if pagedSelect.enabled then
            local rows = motif.select_info.rows
            local cols = motif.select_info.columns
            local cellsPerGrid = rows * cols
            local totalCells = #main.t_selGrid
            pagedSelect.totalPages = math.max(1, math.ceil(totalCells / cellsPerGrid))
        end
    end
    if pagedSelect.enabled and hardReset then
        pagedSelect.currentPage = 1
        pagedSelect.cursorSaved = {}
        rebuildGrid(1)
    end
end

local pageTextSprite
local function drawPageIndicator()
    if not pagedSelect.enabled or not pagedSelect.config.showPageNumber then return end
    if not pageTextSprite then
        pageTextSprite = textImgNew()
        local fontCfg = pagedSelect.config.pageIndicatorFont
        if fontCfg then
            local fontName, b1, b2, b3, b4 = fontCfg:match('^%s*(.-)%s*,%s*(.-)%s*,%s*(.-)%s*,%s*(.-)%s*,%s*(.-)%s*$')
            if fontName then
                textImgSetFont(pageTextSprite, fontName, tonumber(b1) or 0, tonumber(b2) or 0, tonumber(b3) or 0, tonumber(b4) or 0)
            end
        end
    end
    local text = string.format(pagedSelect.config.pageIndicatorText, pagedSelect.currentPage, pagedSelect.totalPages)
    local x, y = pagedSelect.config.pageIndicatorPos[1], pagedSelect.config.pageIndicatorPos[2]
    textImgSetText(pageTextSprite, text)
    textImgSetPos(pageTextSprite, x, y)
    textImgDraw(pageTextSprite)
end

hook.add("start.f_selectScreen", "pagedselect_draw", drawPageIndicator)

return pagedSelect
