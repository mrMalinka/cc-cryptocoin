local toleranceMul = 160 -- adjust this as needed

local function computeMostPopular(ledgerObjects)
    local olen = #ledgerObjects
    if olen == 0 then
        return nil
    elseif olen == 1 then
        return ledgerObjects[1].ledger
    elseif olen == 2 then
        return ledgerObjects[math.random(2)].ledger
    end

    local sum = 0
    for _, l in ipairs(ledgerObjects) do
        sum = sum + l.dist
    end

    local epsilon = toleranceMul * math.log(sum / olen, 10)

    table.sort(ledgerObjects, function(a, b) return a.dist < b.dist end)

    -- filter for chains
    local filteredChain = {}
    local lastDist = -math.huge
    for _, l in ipairs(ledgerObjects) do
        if lastDist + epsilon < l.dist then
            table.insert(filteredChain, l)
        end
        lastDist = l.dist
    end

    -- filter for clusters
    local filtered = {}
    lastDist = -math.huge
    for _, l in ipairs(filteredChain) do
        if math.abs(l.dist - lastDist) > epsilon then
            table.insert(filtered, l)
            lastDist = l.dist
        end
    end

    -- sanitation done, find the most popular one now
    -- map ledger hashes to popularities
    local popularities = {}
    for _, l in ipairs(filtered) do
        local hash = l.ledger:hash()
        popularities[hash] = (popularities[hash] or 0) + 1
    end

    -- find most popular
    local highestCount = -math.huge
    local mostPopularHash = nil
    for hash, count in pairs(popularities) do
        if count > highestCount then
            highestCount = count
            mostPopularHash = hash
        end
    end

    for _, l in ipairs(filtered) do
        if l.ledger:hash() == mostPopularHash then
            return l.ledger
        end
    end

    -- fallback
    return nil
end

return computeMostPopular