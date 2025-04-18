local autoupdate = true
local NETWORK_CHANNEL = 8912
local MINTED_AMOUNT = 15000000000 

local ed25519 = require "ccryptolib.ed25519"
local blake3 = require "ccryptolib.blake3".digest
local walletLib = require "wallets"
local computeMostPopular = require "popularity"


local _modems = { peripheral.find("modem", function(_, modem)
    return modem.isWireless()
end) }
local modem = _modems[1] or error("No wireless modem found!\nPlease attach a wireless ender modem to the computer.")


local function clear()
    term.clear()
    term.setCursorPos(1, 1)
end
local function extends(a, b) -- returns whether a is an extension of b
    for i = 1, #b do
        local elementA = a[i]
        local elementB = b[i]
        
        if not elementA then
            return false
        end
        
        if type(elementB) == "table" then
            if type(elementA) ~= "table" or not extends(elementA, elementB) then
                return false
            end
        elseif elementA ~= elementB then
            return false
        end
    end
    return true
end
local function printC(color, ...)
    local before = term.getTextColor()
    term.setTextColor(color)
    print(...)
    term.setTextColor(before)
end
local function pbinPut(data)
    local width, _ = term.getSize()
    local file = fs.open("___wallet_address", "w")
    file.write(data)
    file.close()
    
    printC(colors.red, "\n" .. ("\x7f"):rep(width))
    shell.run("pastebin put ___wallet_address")
    printC(colors.red, ("\x7f"):rep(width) .. "\n")
    fs.delete("___wallet_address")
end
local function checkTransactionFields(request)
    if type(request) ~= "table" then return false end
    return type(request.from) == "string"
        and type(request.to) == "string"
        and type(request.amount) == "number"
        and type(request.timestamp) == "number"
        and type(request.signature) == "string"
end


Transaction = {}
Transaction.__index = Transaction

function Transaction:new(from, to, amount, timestamp, signature)
    local self = setmetatable({}, Transaction)

    self.from = from -- the senders public key, NOT the wallet address
    self.to = to -- wallet address derived from the recipients public key
    self.amount = amount -- amount of coins

    self.timestamp = timestamp -- prevents replay attacks

    --[[
    ed25519 signature matching the wallet address derived from the public key used in this signature
    the message to sign is equal to textutils.serialize(fields, {compact = true}), fields being a table of:
    self.from, self.to, self.amount, self.timestamp
    ]]
    self.signature = signature 

    return self
end
function Transaction:isValid() -- does NOT check if there were enough funds
    if not checkTransactionFields(self) then return false end

    if self.from == "genesis" then
        return self.amount == MINTED_AMOUNT and self.timestamp == 0 and self.signature == ""
    end
    if not walletLib.isBase58Address(self.to) then return false end
    if walletLib.pubkeyToAddress(self.from) == self.to then return false end

    local message = textutils.serialize({
        self.from,
        self.to,
        self.amount,
        self.timestamp
    }, {compact = true})
    if not ed25519.verify(self.from, message, self.signature) then
        return false
    end

    if self.amount <= 0 then return false end
    if self.amount ~= math.floor(self.amount) then return false end
    if self.timestamp <= 0 then return false end
    
    return true
end


Ledger = {}
Ledger.__index = Ledger

function Ledger:new()
    local self = setmetatable({}, Ledger)

    self.transactions = {}
    return self
end
function Ledger:isValid()
    -- check order of transactions
    for i, tx in ipairs(self.transactions) do
        local previous = self.transactions[i-1]
        if previous then
            if tx.timestamp < previous.timestamp then return false end
        elseif (
            tx.from ~= "genesis" or tx.amount ~= MINTED_AMOUNT or
            tx.timestamp ~= 0 or tx.signature ~= ""
        ) then return false end
            
        -- check signature, fields, etc
        if not tx:isValid() then
            return false
        end
    end

    -- verify no negative balances
    local balances = {}
    for _, tx in ipairs(self.transactions) do
        local sender = walletLib.pubkeyToAddress(tx.from)
        balances[sender] = (balances[sender] or 0) - tx.amount
        balances[tx.to] = (balances[tx.to] or 0) + tx.amount
    end
    
    for addr, bal in pairs(balances) do
        if bal < 0 and addr ~= "genesis" then return false end
    end
 
    return true
end
function Ledger:balanceOf(address)
    local balance = 0
    for _, tx in ipairs(self.transactions) do
        if tx.to == address then
            balance = balance + tx.amount
        end

        local senderAddress = walletLib.pubkeyToAddress(tx.from)
        if senderAddress == address then
            balance = balance - tx.amount
        end
    end
    return balance
end
function Ledger:hash()
    return blake3(
        textutils.serialize(self.transactions, {compact = true})
    )
end



local function syncLedgerByNetwork(comparison)
    local ledgers = {}
    printC(colors.blue, "Gathering ledgers...")
    parallel.waitForAny(
        function()
            sleep(10)
            if #ledgers < 1 and not comparison then
                printC(colors.red, "Timeout passed, but no ledgers were received. Are you sure the modem you're using is an ender modem, or that there are any other nodes on the network?")
    
                parallel.waitForAny(
                    function()
                        repeat
                            sleep(1)
                        until #ledgers > 0
                    end,
                    function()
                        printC(colors.red, "\nClick to stop...")
                        os.pullEvent("mouse_click")
                    end
                )
            end
        end,
        function()
            term.setTextColor(colors.green)
            while true do
                local _, _, _, _, msg, dist = os.pullEvent("modem_message")
                if msg and dist then
                    printC(colors.green, "New ledger received!")

                    -- this check could potentially break a node if it somehow desyncs from
                    -- the network, but were betting on that not happening
                    if extends(msg, comparison) then
                        -- restore metatables
                        setmetatable(msg, Ledger)
                        for _, tx in ipairs(msg.transactions) do
                            setmetatable(tx, Transaction)
                        end

                        table.insert(ledgers, {
                            ledger = msg,
                            dist = dist
                        })
                    end
                end
            end
        end
    )
    term.setTextColor(colors.white)

    if #ledgers < 1 then return nil end

    local realLedger = computeMostPopular(ledgers)
    if not realLedger then error("No valid ledger was found!") end

    return realLedger
end
local function ledgerInit()
    local save = fs.open("ledger.db", "r")
    local cachedLedger = Ledger:new()
    -- get the ledger saved in a file
    if save then
        local contents = save.readAll()
        if contents ~= "" then
            cachedLedger = textutils.unserialize(contents)

            -- restore metatables
            for _, tx in ipairs(cachedLedger.transactions) do
                setmetatable(tx, Transaction)
            end
        end
        save.close()
    end

    local networkLedger = syncLedgerByNetwork(cachedLedger)
    if not networkLedger then return cachedLedger end

    local realLedger
    if networkLedger:isValid() then
        realLedger = networkLedger
    else
        realLedger = cachedLedger
    end

    return realLedger
end

local function handleTransactionRequest(baseLedger, request)
    if not checkTransactionFields(request) then return baseLedger end
    -- check if the timestamp wasnt faked
    if type(request.timestamp) == "number" then
        if not (
            request.timestamp - 2000 < os.epoch()
            and
            request.timestamp + 2000 > os.epoch()
        ) then return baseLedger end
    else return baseLedger end

    local transaction = Transaction:new(
        request.from,
        request.to,
        request.amount,
        request.timestamp,
        request.signature
    )

    -- construct new ledger with the requested transaction
    local newLedger = Ledger:new()
    for i = 1, #baseLedger.transactions do
        table.insert(newLedger.transactions, baseLedger.transactions[i])
    end
    table.insert(newLedger.transactions, transaction)

    if not newLedger:isValid() then
        return baseLedger
    end

    return newLedger
end
local function sendTransactionRequest(ledger, privateKey, receiverAddress, amount)
    local pub = ed25519.publicKey(privateKey)

    local request = {}
    request.from = pub
    request.to = receiverAddress
    request.amount = amount

    request.timestamp = os.epoch()

    request.signature = ed25519.sign(
        privateKey,
        pub,
        textutils.serialize({
            request.from, request.to, request.amount, request.timestamp
        }, {compact = true})
    )

    modem.transmit(NETWORK_CHANNEL, NETWORK_CHANNEL, request)
    return handleTransactionRequest(ledger, request)
end


local function startNode(genesisLedger)
    local _ope = os.pullEvent
    os.pullEvent = os.pullEventRaw

    modem.closeAll()
    modem.open(NETWORK_CHANNEL)

    -- get the (hopefully) universally agreed upon ledger
    local ledger = genesisLedger or ledgerInit()

    parallel.waitForAny(
        function()
            while true do
                local _, _, _, _, msg = os.pullEvent("modem_message")
                if msg then
                    ledger = handleTransactionRequest(ledger, msg)
                end
            end
        end,
        function()
            while true do
                sleep(10)
                modem.transmit(
                    NETWORK_CHANNEL,
                    NETWORK_CHANNEL,
                    ledger
                )
            end
        end,
        function()
            while true do
                do
                    clear()
                    printC(colors.green, "\xbb NODE RUNNING")
                    printC(colors.blue, "Actions:")

                    printC(colors.blue, "\n'transfer':")
                    printC(colors.white, "Transfer money to an address. Irreversible!")

                    printC(colors.blue, "\n'wallet':")
                    printC(colors.white, "Check the status of your wallet.")

                    printC(colors.blue, "\n'stop':")
                    printC(colors.white, "Stop the node.")

                    write("\n> ")
                end
                local input = read():match("^%s*(.-)%s*$")

                clear()
                if input == "transfer" then
                    clear()
                    printC(colors.green, "Transfer funds\n")

                    term.setTextColor(colors.blue)
                    write("Receiver address: ")
                    term.setTextColor(colors.white)
                    local address = read():match("^%s*(.-)%s*$")

                    term.setTextColor(colors.blue)
                    write("Amount: ")
                    term.setTextColor(colors.white)
                    local amount = tonumber(read():match("^%s*(.-)%s*$"))

                    if not amount then
                        printC(colors.red, "Please enter a valid number!")
                    else
                        local previous = ledger:hash()

                        ledger = sendTransactionRequest(
                            ledger, walletLib.getPrivate(), address, amount 
                        )
                        printC(colors.cyan, "\nRequest sent to network...\n")

                        local new = ledger:hash()
                        if previous ~= new then
                            printC(colors.green, "Transaction appears to have been successful!")
                        else
                            printC(colors.red, "The ledger is unchanged. This likely means your transaction failed.")
                        end
                    end

                    print("\nClick to continue...")
                    os.pullEvent("mouse_click")

                elseif input == "wallet" then
                    local address = walletLib.pubkeyToAddress(
                        ed25519.publicKey(walletLib.getPrivate())
                    )

                    printC(colors.blue, "Public address:")
                    print(address)

                    printC(colors.blue, "\nBalance:")
                    print(ledger:balanceOf(address))

                    printC(colors.blue, "\nPut address on pastebin?")
                    write("[y/n]> ")
                    if read() == "y" then
                        pbinPut(address)
                        print("Click to continue...")
                        os.pullEvent("mouse_click")
                    end

                elseif input == "stop" then
                    term.setTextColor(colors.red)
                    print("WARNING: Are you sure you want to stop the node?")
                    print("This will temporarily desync it from the network, and should generally only be done if the node needs updating or maintance.")
                    term.setTextColor(colors.white)
                    write("[y/n]> ")
                    if read() == "y" then return end

                else
                    print("Unknown command!")
                    sleep(1)
                end
            end
        end
    )

    os.pullEvent = _ope
    local save = fs.open("ledger.db", "w")
    save.write(textutils.serialize(ledger, {compact = true}))
    save.close()
end

clear()
local args = {...}
local genesisLedger
if args[1] == "genesis" then
    clear()
    printC(colors.green, "Creating genesis node...")
    genesisLedger = setmetatable({}, Ledger)
    genesisLedger.transactions = {}

    local ownerAddress = walletLib.pubkeyToAddress(
        ed25519.publicKey(walletLib.getPrivate())
    )

    local genesisTx = Transaction:new(
        "genesis",
        ownerAddress,
        MINTED_AMOUNT,
        0,
        ""
    )

    table.insert(genesisLedger.transactions, genesisTx)

    local save = fs.open("ledger.db", "w")
    save.write(textutils.serialize(genesisLedger, {compact = true}))
    save.close()
    
elseif args[1] == "wallet" then
    clear()
    printC(colors.blue, "Your wallet address is:")
    local address = walletLib.pubkeyToAddress(
        ed25519.publicKey(walletLib.getPrivate())
    )
    print(address .. "\n")

    printC(colors.blue, "Placing on pastebin...")
    pbinPut(address)
end


local pname = shell.getRunningProgram()
if pname ~= "startup.lua" then
    if fs.exists("startup.lua") then
        printC(colors.red, "Moving existing `startup.lua` to `_old_startup.lua`")
        fs.move("startup.lua", "_old_startup.lua")
    end

    fs.move(pname, "startup.lua")
end

parallel.waitForAny(
    function()
        startNode(genesisLedger)
    end,
    function()
        while true do
            if autoupdate then
                local f = fs.open("startup.lua", "r")
                local currentHash = blake3(f.readAll())
                f.close()

                local newContentsRequest = http.get("https://raw.githubusercontent.com/mrMalinka/cc-cryptocoin/refs/heads/main/startup.lua")
                if newContentsRequest then
                    local newContents = newContentsRequest.readAll()
                    local newHash = blake3(newContents)

                    if currentHash ~= newHash then
                        local newFile = fs.open("startup.lua", "w")
                        newFile.write(newContents)
                        newFile.close()
                        os.reboot()
                    end
                end
            end
            sleep(60 * 15) -- 15 minute delay
        end
    end
)