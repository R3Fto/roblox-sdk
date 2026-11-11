--!nonstrict
-- R3FTO Roblox SDK: the delivery engine.
--
-- Pure Luau with no Roblox service in here. The clock, the scheduler and every channel attempt are injected, so the
-- same code runs on a game server (task.defer / task.wait / os.clock) and in the plain-Luau tests (a virtual clock).
--
-- One job per stable key (a PurchaseId, or a referral observation). A job has one or more channels, for a receipt the
-- DataStore copy ("storage") and the direct R3FTO delivery ("delivery"). Report K-46:
--   * every channel makes its first attempt immediately, and retries at 60, 180 and 300 seconds after THAT channel's
--     first attempt (offsets from the start, not delays added to each other), at most four attempts in total;
--   * a channel that succeeds stops; the other channel keeps its own remaining attempts;
--   * a repeated submit for the same key never restarts the schedule and never starts a second, parallel sequence;
--   * a Retry-After answer only ever SKIPS scheduled slots that come too early, so it can never add an attempt.
-- The first channel's first attempt runs before the other channels start, so a durable record that already exists in
-- the DataStore (written earlier by another server) is adopted before anything is sent to R3FTO (K-43: the first
-- observation time never changes).

local Engine = {}
Engine.__index = Engine

-- K-46: attempt offsets in seconds from a channel's first attempt.
Engine.OFFSETS = table.freeze({ 0, 60, 180, 300 })

export type AttemptResult = {
	ok: boolean,
	-- set when ok and the channel found or produced the canonical record (the DataStore copy that already existed)
	record: any?,
	-- set when not ok: "storage_failed" | "transport_failed" | "ambiguous" | "throttled" | "rejected"
	kind: string?,
	retryable: boolean?,
	retryAfter: number?,
	detail: string?,
	-- any extra facts the attempt wants kept on the channel (for example the R3FTO receipt id)
	facts: { [string]: any }?,
}

export type ChannelSpec = {
	name: string,
	attempt: (record: any, attemptNumber: number) -> AttemptResult,
}

export type Deps = {
	now: () -> number,
	sleep: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	log: ((level: string, message: string) -> ())?,
}

export type Channel = {
	name: string,
	state: string, -- "pending" | "in_progress" | "succeeded" | "retry_scheduled" | "failed" | "rejected"
	attempts: number,
	firstAttemptAt: number?,
	lastAttemptAt: number?,
	notBefore: number?,
	skippedSlots: number,
	lastError: string?,
	lastDetail: string?,
	facts: { [string]: any },
	spec: ChannelSpec,
}

export type Job = {
	key: string,
	record: any,
	submittedAt: number,
	duplicateSubmits: number,
	channels: { Channel },
	byName: { [string]: Channel },
}

local TERMINAL = { succeeded = true, failed = true, rejected = true }

function Engine.new(deps: Deps)
	assert(type(deps) == "table", "Engine.new needs its dependencies")
	assert(type(deps.now) == "function", "deps.now is required")
	assert(type(deps.sleep) == "function", "deps.sleep is required")
	assert(type(deps.spawn) == "function", "deps.spawn is required")
	local self = setmetatable({}, Engine)
	self._deps = deps
	self._jobs = {} :: { [string]: Job }
	self._count = 0
	return self
end

function Engine:_log(level: string, message: string)
	local log = self._deps.log
	if log then
		log(level, message)
	end
end

-- Runs one scheduled attempt of a channel. Never throws: an attempt that errors is an ambiguous, retryable outcome.
function Engine:_attempt(job: Job, channel: Channel)
	local now = self._deps.now()
	channel.attempts += 1
	channel.state = "in_progress"
	channel.lastAttemptAt = now
	if channel.firstAttemptAt == nil then
		channel.firstAttemptAt = now
	end

	local called, result = pcall(channel.spec.attempt, job.record, channel.attempts)
	if not called or type(result) ~= "table" then
		result = { ok = false, kind = "ambiguous", retryable = true, detail = "the attempt raised an error" }
	end

	local outcome = result :: AttemptResult
	if outcome.facts then
		for key, value in outcome.facts do
			channel.facts[key] = value
		end
	end

	if outcome.ok then
		channel.state = "succeeded"
		channel.lastError = nil
		channel.lastDetail = nil
		if outcome.record ~= nil then
			job.record = outcome.record
		end
		return
	end

	channel.lastError = outcome.kind or "ambiguous"
	channel.lastDetail = outcome.detail
	if outcome.retryable == false then
		channel.state = "rejected"
		return
	end

	if type(outcome.retryAfter) == "number" and outcome.retryAfter > 0 then
		channel.notBefore = self._deps.now() + outcome.retryAfter
	end
	channel.state = if channel.attempts < #Engine.OFFSETS then "retry_scheduled" else "failed"
end

-- Runs the channel's remaining slots (all of them for a fresh channel).
function Engine:_run(job: Job, channel: Channel)
	for index = channel.attempts + 1, #Engine.OFFSETS do
		if TERMINAL[channel.state] then
			return
		end

		if index > 1 then
			local first = channel.firstAttemptAt :: number
			local target = first + Engine.OFFSETS[index]
			if channel.notBefore ~= nil and channel.notBefore > target then
				-- Retry-After asks for a later time than this slot: skip the slot, never add one.
				channel.skippedSlots += 1
				if index == #Engine.OFFSETS then
					channel.state = "failed"
				end
				continue
			end

			local wait = target - self._deps.now()
			if wait > 0 then
				self._deps.sleep(wait)
			end
		end

		self:_attempt(job, channel)
	end

	if not TERMINAL[channel.state] then
		channel.state = "failed"
	end
end

function Engine:_start(job: Job)
	local channels = job.channels
	local first = channels[1]
	-- The first channel's first attempt, before anything else (see the header).
	self:_attempt(job, first)
	for position = 2, #channels do
		local channel = channels[position]
		self._deps.spawn(function()
			self:_run(job, channel)
		end)
	end
	self:_run(job, first)
end

-- Submits a job. A key that already has a job answers that job and `false`; nothing is restarted or duplicated.
function Engine:submit(key: string, record: any, specs: { ChannelSpec }): (Job, boolean)
	assert(type(key) == "string" and #key > 0, "a job needs a key")
	assert(#specs >= 1, "a job needs at least one channel")
	local existing = self._jobs[key]
	if existing then
		existing.duplicateSubmits += 1
		return existing, false
	end

	local job: Job = {
		key = key,
		record = record,
		submittedAt = self._deps.now(),
		duplicateSubmits = 0,
		channels = {},
		byName = {},
	}
	for _, spec in specs do
		local channel: Channel = {
			name = spec.name,
			state = "pending",
			attempts = 0,
			skippedSlots = 0,
			facts = {},
			spec = spec,
		}
		table.insert(job.channels, channel)
		job.byName[spec.name] = channel
	end

	self._jobs[key] = job
	self._count += 1
	self._deps.spawn(function()
		self:_start(job)
	end)
	return job, true
end

function Engine:get(key: string): Job?
	return self._jobs[key]
end

function Engine:jobs(): { [string]: Job }
	return self._jobs
end

-- The overall durability of a receipt job (plan §1c):
--   delivered                 R3FTO acknowledged it after its PostgreSQL commit
--   stored_awaiting_delivery  the DataStore copy exists; R3FTO has not acknowledged (yet); API recovery can read it later
--   memory_only               no durable copy yet; attempts remain
--   not_durable               every attempt ended and no durable copy exists: the evidence is lost if this server stops
function Engine.durability(job: Job): string
	local delivery = job.byName.delivery
	local storage = job.byName.storage
	if delivery and delivery.state == "succeeded" then
		return "delivered"
	end
	if storage and storage.state == "succeeded" then
		return "stored_awaiting_delivery"
	end
	for _, channel in job.channels do
		if not TERMINAL[channel.state] then
			return "memory_only"
		end
	end
	return "not_durable"
end

-- A copy of a job that is safe to hand to publisher code (no functions, no internal references).
function Engine.snapshot(job: Job): { [string]: any }
	local channels = {}
	for _, channel in job.channels do
		local facts = {}
		for key, value in channel.facts do
			facts[key] = value
		end
		channels[channel.name] = {
			state = channel.state,
			attempts = channel.attempts,
			skippedSlots = channel.skippedSlots,
			lastError = channel.lastError,
			lastDetail = channel.lastDetail,
			facts = facts,
		}
	end
	return {
		key = job.key,
		durability = Engine.durability(job),
		duplicateSubmits = job.duplicateSubmits,
		channels = channels,
	}
end

return table.freeze(Engine)
