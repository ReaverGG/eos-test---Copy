extends Control
# ---------------------------------------------------------------------------
@onready var display: Label                    = $Container/Container/MessageDisplay
@onready var peer: EOSGMultiplayerPeer         = EOSGMultiplayerPeer.new()
@onready var container: VBoxContainer          = $Container/Container/Lobby
@onready var play: Button                      = $Container/Container/Play
@onready var name_input: LineEdit              = $Container/Container/NameInput
@onready var player_list: Label                = $Container/Container/PlayerList
@onready var global_container: CenterContainer = $Container

@export var game_scene: PackedScene

# --- Config ---
const MAX_LOGIN_RETRIES    := 3
const MAX_JOIN_RETRIES     := 3          # was 2; one extra attempt costs little
const MAX_PLAYERS          := 4
const CONNECTION_TIMEOUT   := 20.0       # was 15 — give P2P NAT punch-through more time
const LOBBY_BUCKET_ID      := "EosTest"
const P2P_CHANNEL          := "cdEosTest"
const DEFAULT_NAME         := "Player"
const MAX_NAME_LENGTH      := 16
const JOIN_RETRY_BASE_WAIT := 2.0        # seconds; doubles each retry (exponential backoff)
const HEARTBEAT_INTERVAL   := 5.0       # seconds between keep-alive pings
const HEARTBEAT_TIMEOUT    := 15.0      # seconds of silence before declaring peer dead

var local_user_id: String    = ""
var is_server: bool          = false
var peer_user_id: int        = 0
# The lobby ID this instance owns as host (empty if not hosting).
# Used by the joiner to skip only the lobby it literally created,
# not all lobbies owned by a PUID that may be shared on same machine.
var _owned_lobby_id: String  = ""

# Unique ID that survives two instances on the same machine.
var instance_id: String = ""

var _login_retries: int               = 0
var _connection_timer: SceneTreeTimer = null
var _is_connecting: bool              = false

# Heartbeat tracking
var _heartbeat_timer: SceneTreeTimer  = null
var _last_heartbeat_received: float   = 0.0

# peer_id (int) → display name (String)
var _player_names: Dictionary = {}


# ---------------------------------------------------------------------------
#region Initialization
# ---------------------------------------------------------------------------
func _ready() -> void:
	# Each OS process gets a stable instance ID written to disk so that the
	# delete→create Device ID cycle in _attempt_anon_login always uses the
	# exact same string. Without this, EOS can collapse two same-machine
	# instances to the same Product User ID, making the joiner think it owns
	# the host's lobby and skip it.
	var pid := OS.get_process_id()
	var id_path := "user://instance_%d.id" % pid
	if FileAccess.file_exists(id_path):
		var f := FileAccess.open(id_path, FileAccess.READ)
		instance_id = f.get_line().strip_edges()
		f.close()
	if instance_id.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		instance_id = "%d_%08x_%08x" % [pid, rng.randi(), rng.randi()]
		var f := FileAccess.open(id_path, FileAccess.WRITE)
		f.store_line(instance_id)
		f.close()
	print("Instance ID: ", instance_id)

	play.hide()
	player_list.text = ""
	name_input.placeholder_text = DEFAULT_NAME
	name_input.max_length        = MAX_NAME_LENGTH

	if not _init_eos_sdk():
		return

	_setup_multiplayer_signals()
	await _anon_login_with_retry()


func _init_eos_sdk() -> bool:
	var init_options := EOS.Platform.InitializeOptions.new()
	var eos_credentials := EOSCredentials.new()
	init_options.product_name    = eos_credentials.PRODUCT_NAME
	init_options.product_version = eos_credentials.PRODUCT_ID

	var init_result := EOS.Platform.PlatformInterface.initialize(init_options)
	if init_result != EOS.Result.Success:
		printerr("EOS SDK init failed: ", EOS.result_str(init_result))
		_set_display("EOS SDK failed to initialise.")
		return false
	print("EOS SDK initialised.")

	var create_options := EOS.Platform.CreateOptions.new()
	create_options.product_id     = eos_credentials.PRODUCT_ID
	create_options.sandbox_id     = eos_credentials.SANDBOX_ID
	create_options.deployment_id  = eos_credentials.DEPLOYMENT_ID
	create_options.client_id      = eos_credentials.CLIENT_ID
	create_options.client_secret  = eos_credentials.CLIENT_SECRET
	create_options.encryption_key = eos_credentials.ENCRYPTION_KEY
	EOS.Platform.PlatformInterface.create(create_options)
	print("EOS Platform created.")

	EOS.get_instance().logging_interface_callback.connect(_on_logging_interface_callback)
	EOS.Logging.set_log_level(
		EOS.Logging.LogCategory.AllCategories,
		EOS.Logging.LogLevel.Info
	)
	return true


func _setup_multiplayer_signals() -> void:
	# Guard against double-connecting if called again after peer recreation
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _on_logging_interface_callback(msg) -> void:
	msg = EOS.Logging.LogMessage.from(msg) as EOS.Logging.LogMessage
	print("SDK %s | %s" % [msg.category, msg.message])
#endregion


# ---------------------------------------------------------------------------
#region Anonymous Login (with retry)
# ---------------------------------------------------------------------------
func _anon_login_with_retry() -> void:
	_login_retries = 0
	await _attempt_anon_login()


func _attempt_anon_login() -> void:
	_set_display("Logging in... (attempt %d/%d)" % [_login_retries + 1, MAX_LOGIN_RETRIES])

	var delete_options := EOS.Connect.DeleteDeviceIdOptions.new()
	EOS.Connect.ConnectInterface.delete_device_id(delete_options)
	await EOS.get_instance().connect_interface_delete_device_id_callback

	var create_options := EOS.Connect.CreateDeviceIdOptions.new()
	create_options.device_model = OS.get_name() + "_" + instance_id
	EOS.Connect.ConnectInterface.create_device_id(create_options)
	var create_result = await EOS.get_instance().connect_interface_create_device_id_callback
	if create_result and create_result is Dictionary and not create_result.get("success", true):
		printerr("Failed to create device ID: ", create_result)

	if EOS.get_instance().connect_interface_login_callback.is_connected(_on_connect_login_callback):
		EOS.get_instance().connect_interface_login_callback.disconnect(_on_connect_login_callback)
	EOS.get_instance().connect_interface_login_callback.connect(_on_connect_login_callback, CONNECT_ONE_SHOT)

	var credentials := EOS.Connect.Credentials.new()
	credentials.token = null
	credentials.type  = EOS.ExternalCredentialType.DeviceidAccessToken

	var login_options := EOS.Connect.LoginOptions.new()
	login_options.credentials = credentials
	var user_info := EOS.Connect.UserLoginInfo.new()
	user_info.display_name = _get_player_name()
	login_options.user_login_info = user_info
	EOS.Connect.ConnectInterface.login(login_options)


func _on_connect_login_callback(data: Dictionary) -> void:
	if not data.get("success", false):
		printerr("Login failed: ", data)
		_login_retries += 1
		if _login_retries < MAX_LOGIN_RETRIES:
			_set_display("Login failed. Retrying (%d/%d)..." % [_login_retries, MAX_LOGIN_RETRIES])
			await get_tree().create_timer(1.5).timeout
			await _attempt_anon_login()
		else:
			_set_display("Login failed after %d attempts.\nPlease restart." % MAX_LOGIN_RETRIES)
			container.visible = false
		return

	local_user_id = data.local_user_id
	HAuth.product_user_id = local_user_id
	print("Login successful. Local user ID: ", local_user_id)
	_set_display("Logged in!")
	container.visible = true
#endregion


# ---------------------------------------------------------------------------
#region Lobby: Create
# ---------------------------------------------------------------------------
func create_lobby() -> void:
	if not _check_logged_in():
		return

	_set_ui_busy(true)

	var create_options := EOS.Lobby.CreateLobbyOptions.new()
	create_options.bucket_id         = LOBBY_BUCKET_ID
	create_options.max_lobby_members = MAX_PLAYERS
	create_options.local_user_id     = local_user_id
	create_options.presence_enabled  = true

	var new_lobby = await HLobbies.create_lobby_async(create_options)
	if new_lobby == null:
		_set_display("Lobby creation failed.\nCheck your connection and try again.")
		_set_ui_busy(false)
		return

	print("Lobby created: ", new_lobby.lobby_id)
	_owned_lobby_id = new_lobby.lobby_id
	_cleanup_peer()

	var result := peer.create_server(P2P_CHANNEL)
	if result != OK:
		printerr("Failed to create P2P server: ", EOS.result_str(result))
		_set_display("Failed to open P2P server.\nTry again.")
		_set_ui_busy(false)
		return

	multiplayer.multiplayer_peer = peer
	is_server = true
	container.visible = false
	play.hide()

	_player_names[1] = _get_player_name()
	_refresh_player_list()
	_set_display("Lobby created!\nWaiting for players...")
	_start_heartbeat()
#endregion


# ---------------------------------------------------------------------------
#region Lobby: Search & Join (with retry + exponential backoff)
# ---------------------------------------------------------------------------
func search_lobbies() -> void:
	if not _check_logged_in():
		return
	if _is_connecting:
		_set_display("Already connecting, please wait...")
		return

	_is_connecting = true
	_set_ui_busy(true)
	_set_display("Searching for lobbies...")

	var wait := JOIN_RETRY_BASE_WAIT
	for attempt in range(1, MAX_JOIN_RETRIES + 1):
		var succeeded := await _try_join_a_lobby()
		if succeeded:
			_is_connecting = false
			return
		if attempt < MAX_JOIN_RETRIES:
			_set_display("Join attempt %d/%d failed. Retrying in %.0fs..." % [attempt, MAX_JOIN_RETRIES, wait])
			await get_tree().create_timer(wait).timeout
			wait *= 2.0  # exponential backoff

	_is_connecting = false
	_set_ui_busy(false)
	_set_display("Could not find or join any lobby.\nMake sure a host is waiting and try again.")


func _try_join_a_lobby() -> bool:
	# Clean up any lobby we may own before searching — stale host lobbies from
	# a previous session will appear in results and cause us to skip everything.
	await _leave_any_owned_lobbies()

	var lobbies = await HLobbies.search_by_bucket_id_async(LOBBY_BUCKET_ID)
	if not lobbies or lobbies.size() == 0:
		printerr("No lobbies found.")
		return false

	print("Found %d lobby/lobbies. Our local_user_id: %s" % [lobbies.size(), local_user_id])

	for lobby in lobbies:
		var owner_id: String = str(lobby.owner_product_user_id)  # normalise to String
		var our_id:   String = str(local_user_id)

		# Two-layer skip: prefer matching by lobby_id (reliable even when two
		# same-machine instances share a PUID), fall back to PUID comparison.
		var is_own_by_id:   bool = (lobby.lobby_id == _owned_lobby_id and not _owned_lobby_id.is_empty())
		var is_own_by_puid: bool = (owner_id == our_id)
		print("  Lobby %s | owner: %s | ours: %s | own_by_id: %s | own_by_puid: %s" % [
			lobby.lobby_id, owner_id, our_id, is_own_by_id, is_own_by_puid])
		if is_own_by_id:
			print("  → Skipping (matched our own lobby_id)")
			continue
		if is_own_by_puid and not is_own_by_id:
			# PUID matched but lobby_id did not — this is the same-machine collision
			# case. Log a clear warning but DO NOT skip; allow join attempt.
			print("  ⚠ PUID collision detected (same machine?). Attempting to join anyway.")

		var host_id: String = owner_id
		print("Trying lobby: ", lobby.lobby_id, " | Host: ", host_id)

		var join_result = await HLobbies.join_by_id_async(lobby.lobby_id)
		if join_result == null:
			printerr("EOS lobby join failed for: ", lobby.lobby_id)
			continue

		_cleanup_peer()

		var result := peer.create_client(P2P_CHANNEL, host_id)
		if result != OK:
			printerr("P2P client creation failed: ", EOS.result_str(result))
			# Leave the EOS lobby we just joined since P2P failed
			_try_leave_lobby(lobby.lobby_id)
			continue

		multiplayer.multiplayer_peer = peer
		container.visible = false
		_set_display("Found lobby! Connecting...")
		print("Client peer ID: ", multiplayer.get_unique_id())
		_start_connection_timeout()
		return true

	return false


func _try_leave_lobby(lobby_id: String) -> void:
	# Best-effort leave — don't await so we don't stall the join loop
	HLobbies.leave_lobby_async(lobby_id)


func _leave_any_owned_lobbies() -> void:
	# If we previously created a lobby (e.g. during an earlier test run) it may
	# still be listed under our user ID in search results, causing the skip
	# logic to fire on every result and find nothing joinable.
	# NOTE: This only runs if is_server is true — i.e. we somehow got into a
	# host state before clicking Join. Adjust to match your HLobbies API if
	# the method name differs.
	if not is_server:
		return
	print("Was in server state before searching — leaving current lobby first.")
	is_server = false
	_owned_lobby_id = ""
	_cleanup_peer()
	_player_names.clear()
	await HLobbies.leave_current_lobby_async()


# ---------------------------------------------------------------------------
#region Connection Timeout
# ---------------------------------------------------------------------------
func _start_connection_timeout() -> void:
	if _connection_timer != null:
		return
	_connection_timer = get_tree().create_timer(CONNECTION_TIMEOUT)
	_connection_timer.timeout.connect(_on_connection_timeout, CONNECT_ONE_SHOT)


func _cancel_connection_timeout() -> void:
	_connection_timer = null  # one-shot callback checks this before acting


func _on_connection_timeout() -> void:
	if _connection_timer == null:
		return  # was cancelled
	_connection_timer = null
	if not is_server and multiplayer.get_peers().is_empty():
		printerr("Connection timed out after %.0f seconds." % CONNECTION_TIMEOUT)
		_cleanup_peer()
		_is_connecting = false
		_set_ui_busy(false)
		_set_display("Connection timed out.\nThe host may have closed the lobby.\nTry again.")
		container.visible = true
#endregion


# ---------------------------------------------------------------------------
#region Heartbeat (keep-alive to detect silent P2P drops)
# ---------------------------------------------------------------------------
func _start_heartbeat() -> void:
	_stop_heartbeat()
	_last_heartbeat_received = Time.get_ticks_msec() / 1000.0
	_schedule_next_heartbeat()


func _stop_heartbeat() -> void:
	_heartbeat_timer = null


func _schedule_next_heartbeat() -> void:
	if not is_instance_valid(get_tree()):
		return
	_heartbeat_timer = get_tree().create_timer(HEARTBEAT_INTERVAL)
	_heartbeat_timer.timeout.connect(_on_heartbeat_tick, CONNECT_ONE_SHOT)


func _on_heartbeat_tick() -> void:
	if _heartbeat_timer == null:
		return  # heartbeat was stopped

	if not multiplayer.has_multiplayer_peer():
		_stop_heartbeat()
		return

	# Send ping to all peers
	_ping.rpc()

	# Check if we've heard from the other side recently (clients only — server
	# handles individual peer disconnects via peer_disconnected signal)
	if not is_server:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_heartbeat_received > HEARTBEAT_TIMEOUT:
			printerr("Heartbeat timeout — server appears to be gone.")
			_on_server_disconnected()
			return

	_schedule_next_heartbeat()


@rpc("any_peer", "call_remote", "reliable")
func _ping() -> void:
	# Echo back to sender
	_pong.rpc_id(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func _pong() -> void:
	_last_heartbeat_received = Time.get_ticks_msec() / 1000.0
#endregion


# ---------------------------------------------------------------------------
#region Multiplayer Signal Handlers
# ---------------------------------------------------------------------------
func _on_peer_connected(peer_id: int) -> void:
	_cancel_connection_timeout()
	_is_connecting = false
	print("Peer connected: ", peer_id)

	if is_server:
		peer_user_id = peer_id
		# Ask the new peer for their name, and send them the current roster
		_request_name.rpc_id(peer_id)
		_refresh_play_button()
	else:
		# Send our name to the server immediately on connect
		_send_my_name.rpc_id(1, _get_player_name())
		_start_heartbeat()

	_set_display("Player connected.")


func _on_peer_disconnected(peer_id: int) -> void:
	print("Peer disconnected: ", peer_id)
	var gone_name: String = str(_player_names.get(peer_id, "Player %d" % peer_id))
	_player_names.erase(peer_id)
	_refresh_player_list()
	_set_display("%s disconnected." % gone_name)

	if is_server:
		# Broadcast updated list so remaining clients stay in sync
		if not _player_names.is_empty():
			_sync_player_list.rpc(JSON.stringify(_player_names))
		_refresh_play_button()


func _on_connection_failed() -> void:
	_cancel_connection_timeout()
	_is_connecting = false
	printerr("Multiplayer connection failed.")
	_cleanup_peer()
	_set_ui_busy(false)
	_set_display("Connection failed.\nThe host may be unreachable.\nTry again.")
	container.visible = true


func _on_server_disconnected() -> void:
	printerr("Server disconnected unexpectedly.")
	_stop_heartbeat()
	_cleanup_peer()
	_player_names.clear()
	_refresh_player_list()
	_set_display("Lost connection to host.")
	container.visible = true
	play.hide()


func _refresh_play_button() -> void:
	if is_server:
		if multiplayer.get_peers().is_empty():
			play.hide()
		else:
			play.show()
#endregion


# ---------------------------------------------------------------------------
#region Player Name Sync RPCs
# ---------------------------------------------------------------------------

# Server → new client: "tell me your name"
@rpc("authority", "call_remote", "reliable")
func _request_name() -> void:
	_send_my_name.rpc_id(1, _get_player_name())


# Any peer → server: "here is my name"
@rpc("any_peer", "call_remote", "reliable")
func _send_my_name(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var safe_name := _sanitise_name(player_name)
	_player_names[sender_id] = safe_name
	print("Received name from peer %d: %s" % [sender_id, safe_name])
	# Broadcast full updated roster to everyone (JSON keeps RPC args typed)
	_sync_player_list.rpc(JSON.stringify(_player_names))


# Server → all: here is the full player list
@rpc("authority", "call_local", "reliable")
func _sync_player_list(names_json: String) -> void:
	var parsed = JSON.parse_string(names_json)
	if parsed == null or not parsed is Dictionary:
		printerr("_sync_player_list: failed to parse player names JSON")
		return
	_player_names.clear()
	for key in (parsed as Dictionary):
		_player_names[int(key)] = str((parsed as Dictionary)[key])
	_refresh_player_list()
#endregion


# ---------------------------------------------------------------------------
#region Game Start
# ---------------------------------------------------------------------------
@rpc("authority", "call_local", "reliable")
func start_game() -> void:
	play.hide()
	_stop_heartbeat()
	print("--- Game Starting ---")
	print("Unique ID: ", multiplayer.get_unique_id(), " | Is server: ", multiplayer.is_server())

	if game_scene == null:
		printerr("game_scene is not assigned in the inspector!")
		return

	var game_instance = game_scene.instantiate()
	get_tree().current_scene.add_child(game_instance)
	display.hide()
	player_list.hide()
	global_container.hide()
#endregion


# ---------------------------------------------------------------------------
#region Helpers
# ---------------------------------------------------------------------------
func _get_player_name() -> String:
	var raw := name_input.text.strip_edges() if name_input else ""
	return _sanitise_name(raw)


func _sanitise_name(raw: String) -> String:
	var cleaned := raw.strip_edges().left(MAX_NAME_LENGTH)
	return cleaned if cleaned.length() > 0 else DEFAULT_NAME


func _refresh_player_list() -> void:
	if _player_names.is_empty():
		player_list.text = ""
		return
	var lines := PackedStringArray()
	lines.append("Players in lobby:")
	for pid in _player_names:
		var suffix := " (host)" if pid == 1 else ""
		lines.append("  • %s%s" % [_player_names[pid], suffix])
	player_list.text = "\n".join(lines)


func _set_display(msg: String) -> void:
	if display:
		display.text = msg


func _set_ui_busy(busy: bool) -> void:
	for child in container.get_children():
		if child is Button:
			child.disabled = busy


func _check_logged_in() -> bool:
	if local_user_id.is_empty():
		_set_display("Not logged in yet.\nPlease wait...")
		return false
	return true


func _cleanup_peer() -> void:
	_stop_heartbeat()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
#endregion


# ---------------------------------------------------------------------------
#region Button Callbacks
# ---------------------------------------------------------------------------
func _on_create_pressed() -> void:
	create_lobby()


func _on_join_pressed() -> void:
	search_lobbies()


func _on_play_pressed() -> void:
	if not is_server:
		printerr("Non-server tried to press Play. Ignoring.")
		return
	if multiplayer.get_peers().is_empty():
		_set_display("No players connected yet!")
		return
	print("Starting game. Connected peers: ", multiplayer.get_peers())
	start_game.rpc()
#endregion
