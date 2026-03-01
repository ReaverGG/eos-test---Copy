# game_scene.gd
extends Node2D

@onready var spawner: MultiplayerSpawner = $PlayerSpawner
@onready var container: Node = $PlayerContainer

func _ready() -> void:
	if not multiplayer.is_server():
		return
	
	# Spawn a player for every connected peer, including the server itself
	_spawn_player(multiplayer.get_unique_id())
	for peer_id in multiplayer.get_peers():
		_spawn_player(peer_id)
	
	# Spawn for anyone who joins later (if you support late join)
	multiplayer.peer_connected.connect(_spawn_player)

func _spawn_player(peer_id: int) -> void:
	var player = preload("res://scenes/Player.tscn").instantiate()
	player.name = str(peer_id)  # CRITICAL: name must match peer ID for authority to work
	container.add_child(player)
