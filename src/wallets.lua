local blake3 = require "ccryptolib.blake3".digest
local rand = require "ccryptolib.random"
rand.initWithTiming()

-- gets or creates a wallet
local function getPrivate()
    local drive
    if peripheral.getType("left") == "drive" then
        drive = peripheral.wrap("left")
    elseif peripheral.getType("right") == "drive" then
        drive = peripheral.wrap("right")
    else
        error("Please place only one disk drive on the left or righ side of the computer.")
    end
    assert(drive.isDiskPresent(), "No disk inside disk drive!")
    drive.setDiskLabel("Crypto Wallet")

    local path = fs.combine(drive.getMountPath(), "wallet.db")
    if fs.exists(path) and not fs.isDir(path) then
        local file = fs.open(path, "r")
        local priv = file.read(32)
        if priv then
            if #priv ~= 32 then
                error(("The wallet file may be corrupted.\nExpected length: 32, got: %d"):format(#priv))
            end
        else
            error("Wallet file was empty. The file may be corrupted.")
        end
        
        file.close()
        return priv
    end

    -- generate new if it was missing
    local priv = blake3(rand.random(64), 32)
    local file = fs.open(path, "w")
    file.write(priv)
    file.close()
    return priv
end

local BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local function pubkeyToAddress(pubkey)
    local checksum = blake3(blake3(pubkey), 4)
    local payload = pubkey .. checksum
    
    local leadingZeros = 0
    for i = 1, #payload do
        if payload:byte(i) ~= 0 then break end
        leadingZeros = leadingZeros + 1
    end
    
    local num = {}
    for i = 1, #payload do
        local byte = payload:byte(i)
        for j = #num, 1, -1 do
            byte = byte + num[j] * 256
            num[j] = byte % 58
            byte = math.floor(byte / 58)
        end
        while byte > 0 do
            table.insert(num, 1, byte % 58)
            byte = math.floor(byte / 58)
        end
    end
    
    local result = string.rep('1', leadingZeros)
    for _, d in ipairs(num) do
        result = result .. BASE58_ALPHABET:sub(d + 1, d + 1)
    end
    
    return result
end


local function _buildBase58Map()
    local map = {}
    for i = 1, #BASE58_ALPHABET do
        local char = BASE58_ALPHABET:sub(i, i)
        map[char] = i - 1
    end
    return map
end
local function _base58Decode(input)
    local base58Map = _buildBase58Map()
    local num = {0}
    for i = 1, #input do
        local c = input:sub(i, i)
        local digit = base58Map[c]

        if not digit then return nil end

        local carry = digit
        for j = #num, 1, -1 do
            local n = num[j] * 58 + carry
            num[j] = n % 256
            carry = math.floor(n / 256)
        end
        while carry > 0 do
            table.insert(num, 1, carry % 256)
            carry = math.floor(carry / 256)
        end

    end
    local leadingZeros = 0
    for i = 1, #input do
        if input:sub(i, i) ~= '1' then break end
        leadingZeros = leadingZeros + 1
    end
    for i = 1, leadingZeros do
        table.insert(num, 1, 0)
    end
    return string.char(table.unpack(num))
end

-- verifies that an address is a real base58 one 
local function isBase58Address(address)
    local payload, err = _base58Decode(address)

    if not payload then return false end
    if #payload ~= 36 then return false end

    local pubkey = payload:sub(1, 32)
    local checksum = payload:sub(33, 36)
    local computedChecksum = blake3(blake3(pubkey), 4)

    return checksum == computedChecksum
end

return {
    getPrivate = getPrivate,
    pubkeyToAddress = pubkeyToAddress,
    isBase58Address = isBase58Address
}