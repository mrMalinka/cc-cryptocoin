local function computeDynamicEpsilon(distances)
    local n = #distances
    if n <= 1 then
        return 200
    end

    local q1_idx = math.floor(0.25 * n)
    if q1_idx < 1 then q1_idx = 1 end
    
    local q3_idx = math.ceil(0.75 * n)
    if q3_idx > n then q3_idx = n end

    local q1 = distances[q1_idx]
    local q3 = distances[q3_idx]
    local iqr = q3 - q1

    return 2 * iqr / (n^(1/3))
end

local function binarySearchLower(arr, target)
    local left, right = 1, #arr
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if arr[mid] < target then
            left = mid + 1
        else
            right = mid - 1
        end
    end
    return left
end

local function binarySearchUpper(arr, target)
    local left, right = 1, #arr
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if arr[mid] > target then
            right = mid - 1
        else
            left = mid + 1
        end
    end
    return right
end

local function computeMostPopular(ledgers)
    local popularities = {}
    local distances = {}

    for _, ledgerObject in ipairs(ledgers) do
        table.insert(distances, ledgerObject.dist)
    end
    table.sort(distances)

    local epsilon = computeDynamicEpsilon(distances)

    for _, ledgerObject in ipairs(ledgers) do
        local ledger = ledgerObject.ledger
        setmetatable(ledger, Ledger)
        local hash = ledger:hash()
        local currentDist = ledgerObject.dist

        local lower, upper = currentDist - epsilon, currentDist + epsilon
        local firstIndex = binarySearchLower(distances, lower)
        local lastIndex = binarySearchUpper(distances, upper)
        local clusterSize = lastIndex - firstIndex + 1

        if not popularities[hash] then
            popularities[hash] = { value = 0.0, dist = currentDist }
        end
        popularities[hash].value = popularities[hash].value + (1.0 / (clusterSize^1.5))
    end

    local maxValue, maxHash = -math.huge, nil
    for hash, data in pairs(popularities) do
        if data.value > maxValue then
            maxValue, maxHash = data.value, hash
        end
    end

    for _, ledgerObject in ipairs(ledgers) do
        if ledgerObject.ledger:hash() == maxHash and ledgerObject.ledger:isValid() then
            return ledgerObject.ledger
        end
    end
    return nil
end

return computeMostPopular