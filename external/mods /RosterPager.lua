--=============================================================================
-- RosterPager  -  Multi-page roster browser for Ikemen GO
--=============================================================================
-- Drop this file in  external/mods/
-- Ativacao automatica quando o numero de personagens excede a grade.
--=============================================================================
-- Configuracao  (edite apenas esta secao)
--=============================================================================

local config = {

    -- Botoes para navegacao direta de pagina (nomes dos botoes).
    -- Deixe vazio para desativar.
    pagenavUp   = {},    -- Ex.: { 'd' } para L1
    pagenavDown = {},    -- Ex.: { 'w' } para L2

    -- Mudanca de pagina ao passar do ultimo para o primeiro slot (ou vice-versa).
    edgePaging = true,

    -- Indicador de pagina na tela
    showPageNumber   = true,
    pageIndicatorPos = {160, 220},

    -- nil = herda a configuracao do motif (page.indicator.font).
    -- Para customizar, use o formato:  'font/arquivo.def,banco,R,G,B'
    pageIndicatorFont = nil,
    pageIndicatorText = "Pagina %d/%d",
}

--=============================================================================
-- Estado interno  (nao mexa)
--=============================================================================

local state = {
    enabled     = false,
    currentPage = 1,
    totalPages  = 1,
    pageSize    = 0,
}

-- Deteccao de borda de subida (rising edge) por comando.
local held = {}
local function rising(cmd, key)
    local now = getInput(cmd, key) and true or false
    local t = held[cmd] or {}
    local was = t[key] or false
    t[key] = now
    held[cmd] = t
    return now and not was
end

--=============================================================================
-- Utilitarios
--=============================================================================

local function gridSize()
    return motif.select_info.rows, motif.select_info.cols or motif.select_info.columns
end

-- Converte celula visivel (1-indexada) para o indice global no roster.
local function toGlobalCell(cell)
    local ps = state.pageSize
    if ps == 0 then return cell end
    if cell < 1 or cell > ps then return cell end
    return (state.currentPage - 1) * ps + cell
end

-- Toca um som do motif. Se nao especificado, usa o som padrao de cursor.
local function playSnd(snd)
    if not snd then
        if not motif.select_info.cursor then return end
        snd = motif.select_info.cursor.move.snd
    end
    if snd then
        sndPlay(motif.Snd, snd[1], snd[2])
    end
end

-- Aplica posicao do cursor para um jogador, inclusive o calculo de cell.
local function setCursor(player, x, y)
    local _, cols = gridSize()
    start.c[player].selX = x
    start.c[player].selY = y
    start.c[player].cell = x + cols * y
end

--=============================================================================
-- Hook: f_selGrid  –  redireciona consultas de celula para a pagina atual
--=============================================================================

local origSelGrid = start.f_selGrid
start.f_selGrid = function(cell, slot)
    if not state.enabled then
        return origSelGrid(cell, slot)
    end
    return origSelGrid(toGlobalCell(cell), slot)
end

--=============================================================================
-- Gerenciamento da grid
--=============================================================================

-- Preenche start.t_grid com os personagens de uma pagina.
local function rebuildGrid(page)
    local rows, cols = gridSize()
    if not rows or not cols then return end
    local offset = (page - 1) * state.pageSize
    for r = 1, rows do
        for c = 1, cols do
            local idx = (r - 1) * cols + c
            local cell = start.t_grid[r][c]
            local data = origSelGrid(offset + idx)
            if data and data.char then
                cell.char = data.char
                cell.char_ref = data.char_ref
                cell.hidden = data.hidden
            else
                cell.char = nil
                cell.char_ref = nil
                cell.hidden = nil
            end
            cell.face_data = nil
            cell.face2_data = nil
        end
    end
end

--=============================================================================
-- Posicionamento do cursor ao mudar de pagina
--=============================================================================

-- Encontra o primeiro slot valido em uma coluna (de cima para baixo ou vice-versa).
local function columnEdge(col, fromBottom)
    local rows, _ = gridSize()
    local startY, endY, inc
    if fromBottom then
        startY, endY, inc = rows - 1, 0, -1
    else
        startY, endY, inc = 0, rows - 1, 1
    end
    for y = startY, endY, inc do
        local g = start.t_grid[y + 1] and start.t_grid[y + 1][col + 1]
        if g and g.char and g.skip ~= 1 and g.hidden ~= 2 then
            return col, y
        end
    end
    return nil
end

-- Encontra o primeiro slot valido em toda a pagina (fallback).
local function firstValidCell(reverse)
    local rows, cols = gridSize()
    local first, last, inc
    if reverse then
        first, last, inc = state.pageSize, 1, -1
    else
        first, last, inc = 1, state.pageSize, 1
    end
    for cell = first, last, inc do
        local x = (cell - 1) % cols
        local y = math.floor((cell - 1) / cols)
        local g = start.t_grid[y + 1] and start.t_grid[y + 1][x + 1]
        if g and g.char and g.skip ~= 1 and g.hidden ~= 2 then
            return x, y
        end
    end
    return 0, 0
end

-- Navega para uma pagina adjacente e retorna a posicao de pouso.
local function navigatePage(delta, side, curX, curY)
    local np = state.currentPage + delta
    if np < 1 or np > state.totalPages then
        if not motif.select_info.wrapping then
            return false, curX, curY
        end
        np = np < 1 and state.totalPages or 1
    end
    state.currentPage = np
    rebuildGrid(np)
    start.needUpdateDrawList = true
    local x, y = columnEdge(curX, delta < 0)
    if not x then
        x, y = firstValidCell(delta < 0)
    end
    return true, x, y
end

-- Tenta navegar; se conseguir, toca o som (opcional) e retorna a nova posicao.
local function tryNavigate(delta, side, curX, curY, snd)
    local ok, nx, ny = navigatePage(delta, side, curX, curY)
    if ok then
        playSnd(snd)
        return true, nx, ny
    end
    return false, curX, curY
end

--=============================================================================
-- Hook: f_cellMovement  –  UP/DOWN nas bordas da grade mudam de pagina
--=============================================================================

local origCellMovement = start.f_cellMovement
start.f_cellMovement = function(selX, selY, cmd, side, snd)
    if not state.enabled then
        return origCellMovement(selX, selY, cmd, side, snd)
    end
    local rows, _ = gridSize()
    local upKey   = motif.select_info.cell.up.key
    local downKey = motif.select_info.cell.down.key

    if #config.pagenavUp > 0 and rising(cmd, config.pagenavUp) then
        local ok, nx, ny = tryNavigate(-1, side, selX, selY, snd)
        if ok then return nx, ny end
    end
    if #config.pagenavDown > 0 and rising(cmd, config.pagenavDown) then
        local ok, nx, ny = tryNavigate(1, side, selX, selY, snd)
        if ok then return nx, ny end
    end

    local _, cols = gridSize()
    local atBottom = selY >= rows - 1
    local emptyRowBelow = false
    local nextRow = start.t_grid[selY + 2]
    if nextRow then
        local hasChar = false
        for c = 1, cols do
            if nextRow[c] and nextRow[c].char then
                hasChar = true
                break
            end
        end
        emptyRowBelow = not hasChar
    end

    if (atBottom or emptyRowBelow) and rising(cmd, downKey) then
        if emptyRowBelow then
            state.currentPage = 1
            rebuildGrid(1)
            start.needUpdateDrawList = true
            local nx, ny = columnEdge(selX, false)
            if not nx then nx, ny = firstValidCell(false) end
            playSnd(snd)
            return nx, ny
        end
        if atBottom then
            local ok, nx, ny = tryNavigate(1, side, selX, selY, snd)
            if ok then return nx, ny end
            return selX, selY
        end
    end

    if selY == 0 and rising(cmd, upKey) then
        local ok, nx, ny = tryNavigate(-1, side, selX, selY, snd)
        if ok then return nx, ny end
        return selX, selY
    end

    return origCellMovement(selX, selY, cmd, side, snd)
end

--=============================================================================
-- Hook: f_selectMenu  –  edge paging nas bordas horizontais
--=============================================================================

local origSelectMenu = start.f_selectMenu
start.f_selectMenu = function(side, cmd, player, member, selectState)
    if state.enabled and config.edgePaging and start.c and start.c[player] then
        local rows, cols = gridSize()
        local selX, selY = start.c[player].selX, start.c[player].selY
        local lastX, lastY = cols - 1, rows - 1

        if selX == lastX and selY == lastY and rising(cmd, motif.select_info.cell.right.key) then
            local ok, nx, ny = tryNavigate(1, side, selX, selY)
            if ok then
                setCursor(player, nx, ny)
                return selectState, false
            end
        elseif selX == 0 and selY == 0 and rising(cmd, motif.select_info.cell.left.key) then
            local ok, nx, ny = tryNavigate(-1, side, selX, selY)
            if ok then
                setCursor(player, nx, ny)
                return selectState, false
            end
        end
    end
    return origSelectMenu(side, cmd, player, member, selectState)
end

--=============================================================================
-- Inicializacao
--=============================================================================

-- Tenta herdar a configuracao de fonte do motif (page.indicator.font).
local function resolveFont()
    if config.pageIndicatorFont then
        return
    end
    local pi = motif.select_info.page
    if not pi or not pi.indicator then return end
    local raw = pi.indicator.font
    if not raw then return end
    -- Formato do motif:  fontno, bank, align, R, G, B, A, -1
    -- Precisamos do path do arquivo de fonte, que nao esta disponivel
    -- em tempo de execucao via Lua. O usuario deve configurar
    -- pageIndicatorFont manualmente se quiser uma fonte customizada.
    -- Porem, aproveitamos o texto padrao do motif se o nosso estiver vazio.
    if config.pageIndicatorText == "Pagina %d/%d" and pi.indicator.text then
        config.pageIndicatorText = pi.indicator.text
    end
end

local function init()
    local rows, cols = gridSize()
    if not rows or not cols then return end
    state.pageSize = rows * cols
    local totalChars = #main.t_selGrid
    state.totalPages = math.max(1, math.ceil(totalChars / state.pageSize))
    state.enabled = totalChars > state.pageSize
    if state.enabled then
        rebuildGrid(state.currentPage)
    end
    resolveFont()
end

local origSelectReset = start.f_selectReset
start.f_selectReset = function(hardReset, preserveProgress)
    if state.enabled and hardReset then
        state.currentPage = 1
    end
    origSelectReset(hardReset, preserveProgress)
    init()
end

--=============================================================================
-- Indicador de pagina (draw)
--=============================================================================

local textSprite
local function drawPageIndicator()
    if not state.enabled or not config.showPageNumber then return end
    if start.p and start.p[1] and start.p[2]
        and start.p[1].selEnd and start.p[2].selEnd then
        return
    end
    if not textSprite then
        textSprite = textImgNew()
        local fontCfg = config.pageIndicatorFont
        if fontCfg then
            local name, bank, r, g, b = fontCfg:match('^(.-),%s*(.-),%s*(.-),%s*(.-),%s*(.-)$')
            if name then
                textImgSetFont(textSprite, fontNew(name, -1))
                textImgSetBank(textSprite, tonumber(bank) or 0)
                textImgSetColor(textSprite, tonumber(r) or 255, tonumber(g) or 255, tonumber(b) or 255)
            end
        end
    end
    local text = string.format(config.pageIndicatorText, state.currentPage, state.totalPages)
    textImgSetText(textSprite, text)
    textImgReset(textSprite)
    textImgSetPos(textSprite, config.pageIndicatorPos[1], config.pageIndicatorPos[2])
    textImgDraw(textSprite)
end

hook.add("start.f_selectScreen", "RosterPager", drawPageIndicator)

return {
    config = config,
    state = state,
}
