--[[
    FishingServer  (Script)
    Letakkan di: ServerScriptService
    Fungsi: logika memancing (lempar, ikan menyambar, tarik, hadiah, simpan koin).
    Pasangan dari LocalScript "FishingClient" di StarterPlayerScripts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

---------------------------------------------------------------------
-- PENGATURAN
---------------------------------------------------------------------
local MIN_WAIT = 3 -- detik minimal sampai ikan menyambar
local MAX_WAIT = 8 -- detik maksimal sampai ikan menyambar
local REEL_WINDOW = 2 -- detik waktu untuk menarik setelah ikan menyambar
local LATENCY_GRACE = 0.3 -- toleransi lag
local CAST_COOLDOWN = 1 -- jeda minimal antar lemparan

-- Peluang tiap rarity (makin besar makin sering)
local RARITY_WEIGHTS = {
	Common = 60,
	Uncommon = 25,
	Rare = 10,
	Epic = 4,
	Legendary = 1,
}

-- Daftar ikan
local FISH = {
	{ name = "Ikan Teri", rarity = "Common", price = 5 },
	{ name = "Ikan Mas", rarity = "Common", price = 8 },
	{ name = "Ikan Lele", rarity = "Common", price = 10 },
	{ name = "Ikan Nila", rarity = "Uncommon", price = 20 },
	{ name = "Ikan Gurame", rarity = "Uncommon", price = 28 },
	{ name = "Ikan Kakap", rarity = "Rare", price = 60 },
	{ name = "Ikan Tuna", rarity = "Rare", price = 80 },
	{ name = "Ikan Pari", rarity = "Epic", price = 200 },
	{ name = "Hiu Kecil", rarity = "Epic", price = 260 },
	{ name = "Ikan Naga Emas", rarity = "Legendary", price = 1000 },
}

-- Item sampah (kadang muncul, tidak dihitung ikan)
local JUNK_CHANCE = 0.08
local JUNK = {
	{ name = "Sepatu Bekas", price = 1 },
	{ name = "Kaleng Karatan", price = 1 },
	{ name = "Rumput Laut", price = 2 },
}

---------------------------------------------------------------------
-- REMOTE EVENTS (dibuat otomatis jika belum ada)
---------------------------------------------------------------------
local remotes = ReplicatedStorage:FindFirstChild("FishingRemotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "FishingRemotes"
	remotes.Parent = ReplicatedStorage
end

local function getRemote(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end

local CastEvent = getRemote("Cast")
local ReelEvent = getRemote("Reel")
local BiteEvent = getRemote("Bite")
local ResultEvent = getRemote("Result")

---------------------------------------------------------------------
-- DATA (simpan koin & jumlah ikan)
---------------------------------------------------------------------
local store = DataStoreService:GetDataStore("FishingGame_v1")

local function loadData(player, coins, caught)
	local ok, data = pcall(function()
		return store:GetAsync("p_" .. player.UserId)
	end)
	if ok and type(data) == "table" then
		coins.Value = data.coins or 0
		caught.Value = data.caught or 0
	elseif not ok then
		warn("Gagal memuat data " .. player.Name .. ": " .. tostring(data))
	end
end

local function saveData(player)
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		return
	end
	local coins = stats:FindFirstChild("Koin")
	local caught = stats:FindFirstChild("Ikan")
	if not (coins and caught) then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync("p_" .. player.UserId, {
			coins = coins.Value,
			caught = caught.Value,
		})
	end)
	if not ok then
		warn("Gagal menyimpan data " .. player.Name .. ": " .. tostring(err))
	end
end

---------------------------------------------------------------------
-- SESI MEMANCING PER PEMAIN
---------------------------------------------------------------------
-- state: "idle" | "waiting" | "bite"
local sessions = {}

local function newSession()
	return { state = "idle", token = 0, biteAt = 0, lastCast = 0 }
end

local function pickFish()
	-- Sampah
	if math.random() < JUNK_CHANCE then
		local j = JUNK[math.random(#JUNK)]
		return { name = j.name, rarity = nil, price = j.price, isJunk = true }
	end

	-- Tentukan rarity berdasarkan bobot
	local total = 0
	for _, w in pairs(RARITY_WEIGHTS) do
		total += w
	end
	local roll = math.random() * total
	local chosen = "Common"
	for rarity, w in pairs(RARITY_WEIGHTS) do
		roll -= w
		if roll <= 0 then
			chosen = rarity
			break
		end
	end

	-- Pilih ikan acak dari rarity tersebut
	local pool = {}
	for _, fish in ipairs(FISH) do
		if fish.rarity == chosen then
			table.insert(pool, fish)
		end
	end
	return pool[math.random(#pool)]
end

local function resetSession(session)
	session.state = "idle"
	session.token += 1 -- membatalkan timer yang masih berjalan
end

---------------------------------------------------------------------
-- EVENT DARI CLIENT
---------------------------------------------------------------------
CastEvent.OnServerEvent:Connect(function(player)
	local session = sessions[player]
	if not session then
		return
	end

	if session.state ~= "idle" then
		return
	end

	-- Anti-spam
	if os.clock() - session.lastCast < CAST_COOLDOWN then
		ResultEvent:FireClient(player, false, "Tunggu sebentar sebelum melempar lagi.")
		return
	end

	session.lastCast = os.clock()
	session.state = "waiting"
	session.token += 1
	local myToken = session.token

	-- Tunggu ikan menyambar
	task.delay(math.random() * (MAX_WAIT - MIN_WAIT) + MIN_WAIT, function()
		if sessions[player] ~= session or session.token ~= myToken or session.state ~= "waiting" then
			return
		end

		session.state = "bite"
		session.biteAt = os.clock()
		BiteEvent:FireClient(player)

		-- Jika tidak ditarik tepat waktu, ikan kabur
		task.delay(REEL_WINDOW + LATENCY_GRACE, function()
			if sessions[player] ~= session or session.token ~= myToken or session.state ~= "bite" then
				return
			end
			resetSession(session)
			ResultEvent:FireClient(player, false, "Terlambat! Ikannya kabur.")
		end)
	end)
end)

ReelEvent.OnServerEvent:Connect(function(player)
	local session = sessions[player]
	if not session then
		return
	end

	if session.state == "waiting" then
		-- Menarik terlalu cepat
		resetSession(session)
		ResultEvent:FireClient(player, false, "Terlalu cepat! Ikan kabur.")
		return
	end

	if session.state ~= "bite" then
		return
	end

	local elapsed = os.clock() - session.biteAt
	if elapsed > REEL_WINDOW + LATENCY_GRACE then
		return -- timer di atas yang akan menangani
	end

	resetSession(session)

	local fish = pickFish()
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		stats.Koin.Value += fish.price
		if not fish.isJunk then
			stats.Ikan.Value += 1
		end
	end

	if fish.isJunk then
		ResultEvent:FireClient(player, true, "Kamu dapat " .. fish.name .. "...", nil, fish.price)
	else
		ResultEvent:FireClient(player, true, "Kamu mendapatkan " .. fish.name .. "!", fish.rarity, fish.price)
	end
end)

---------------------------------------------------------------------
-- PEMAIN MASUK / KELUAR
---------------------------------------------------------------------
Players.PlayerAdded:Connect(function(player)
	sessions[player] = newSession()

	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	stats.Parent = player

	local coins = Instance.new("IntValue")
	coins.Name = "Koin"
	coins.Parent = stats

	local caught = Instance.new("IntValue")
	caught.Name = "Ikan"
	caught.Parent = stats

	loadData(player, coins, caught)
end)

Players.PlayerRemoving:Connect(function(player)
	saveData(player)
	sessions[player] = nil
end)

-- Simpan semua data saat server ditutup
game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		saveData(player)
	end
end)
