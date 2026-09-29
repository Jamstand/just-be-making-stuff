--!strict
-- Names of the RemoteEvents the server creates under ReplicatedStorage.Remotes.
-- Phase 1 needs NO client -> server remotes: buying, stealing and slamming use ProximityPrompts,
-- collecting uses a touch pad and the Towel Snap is a Tool. All of those are validated on the server.
return {
	Folder = "Remotes",
	Events = {
		"State", -- server -> client: full StateView for that player
		"Toast", -- server -> client: short message for one player {text, kind}
		"Announce", -- server -> all: banner text + color
		"Carry", -- server -> client: carry started/ended {name, side, rarity} or nil
	},
}
