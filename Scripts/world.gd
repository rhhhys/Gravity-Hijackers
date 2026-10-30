extends Node

signal player_added(peer_id)

@onready var main_menu = $CanvasLayer/MainMenu
@onready var address_entry = $CanvasLayer/MainMenu/MenuPanel/MarginContainer/VBoxContainer/AddressEntry
@onready var username_entry = $CanvasLayer/MainMenu/MenuPanel/MarginContainer/VBoxContainer/UsernameEntry
@onready var hud = $CanvasLayer/HUD
@onready var leaderboard = $CanvasLayer/Leaderboard
@onready var esc_menu = $CanvasLayer/EscMenu
@onready var health_bar = $CanvasLayer/HUD/HealthBar
@onready var menu_camera = $MenuCamera
@onready var host_label = $CanvasLayer/HUD/HostAddressLabel
@onready var username_label = $CanvasLayer/HUD/UsernameLabel
# @onready var radio = $CanvasLayer/Radio
var world_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var playerScene = preload("res://scenes/player.tscn")
@onready var leaderboard_entry_scene = preload("res://scenes/LeaderboardEntry.tscn")

var tracked = false
var player
var connected_player_ids = []
var random_camera_direction = Vector3(randf_range(-10, 10), randf_range(-10, 10), randf_range(-10, 10))

const PORT = 9999
var enet_peer = ENetMultiplayerPeer.new()

func get_local_ip() -> String:
	var addresses = IP.get_local_addresses()
	var fallback_192 = ""
	var fallback_172 = ""
	
	for ip in addresses:
		if ip.begins_with("10."): # prioritize 255.0.0.0 subnet masks
			return ip
		if ip.begins_with("192.168."):
			fallback_192 = ip
		if ip.begins_with("172."): # take precaution around 172 addresses because of vn bridges
			fallback_172 = ip
	
	if fallback_192 != "":
		return fallback_192
	if fallback_172 != "":
		return fallback_172
	return "not found"

func _ready() -> void:
	Global.worldNode = self

func _on_host_button_pressed():
	if not username_entry.text:
		username_entry.placeholder_text = "Enter a username before joining/hosting"
		return
	
	username_label.text = "Player username: %s" % username_entry.text
	host_label.text = "Host address: %s" % get_local_ip()
	
	main_menu.hide()
	hud.show()
	
	enet_peer.create_server(PORT)
	multiplayer.multiplayer_peer = enet_peer
	multiplayer.peer_connected.connect(add_player)
	multiplayer.peer_disconnected.connect(remove_player)
	
	add_player(multiplayer.get_unique_id())
	
	#upnp_setup()
func _on_join_button_pressed():
	if not username_entry.text:
		username_entry.placeholder_text = "Enter a username before joining/hosting"
		return
	
	username_label.text = "Player username: %s" % username_entry.text
	host_label.text = ""
	
	main_menu.hide()
	hud.show()
	
	enet_peer.create_client(address_entry.text, PORT)
	multiplayer.multiplayer_peer = enet_peer
	multiplayer.server_disconnected.connect(
		func(): 
			hud.hide()
			leaderboard.hide()
			esc_menu.hide()
			main_menu.show()
	)

func _on_menu_button_down():
	multiplayer.multiplayer_peer.close()
	get_tree().change_scene_to_file("res://scenes/testWorld.tscn")

func _on_quit_button_down():
	get_tree().quit()

func _on_close_button_down():
	esc_menu.hide()
	hud.show()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_button_pressed():
	get_tree().change_scene_to_file("res://Settings/SettingsMenu.tscn")

func upnp_setup():
	var upnp = UPNP.new()
	
	var discover_result = upnp.discover()
	assert(discover_result == UPNP.UPNP_RESULT_SUCCESS, "UPNP Discover Failed! Error %s" % discover_result)

	assert(upnp.get_gateway() and upnp.get_gateway().is_valid_gateway(), "UPNP Invalid Gateway!")

	var map_result = upnp.add_port_mapping(PORT)
	assert(map_result == UPNP.UPNP_RESULT_SUCCESS, "UPNP Port Mapping Failed! Error %s" % map_result)
	
	print("Success! Join Address: %s" % upnp.query_external_address())

func _physics_process(delta):
	menu_camera.rotation_degrees += random_camera_direction * delta
	if tracked and player:
		get_tree().call_group("enemy", "update_target_location", player.global_transform.origin)

func _unhandled_input(event):
	if Input.is_action_just_pressed("quit") and enet_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED: # allows for game close in main menu but not ingame
		get_tree().quit()

func add_player(peer_id):
	player = playerScene.instantiate()
	player.name = str(peer_id)
	add_child(player)
	tracked = true
	
	var group_counts = {get_tree().get_node_count_in_group("RedTeam"): "RedTeam", get_tree().get_node_count_in_group("BlueTeam"): "BlueTeam"} # team 2 will override team 1 when both are even since keys match
	var smallest_team = group_counts[min(get_tree().get_node_count_in_group("RedTeam"), get_tree().get_node_count_in_group("BlueTeam"))] if len(group_counts) > 1 else ["RedTeam", "BlueTeam"].pick_random() # removes bias to one team when both teams are even

	update_player_data(peer_id, {"groups": [smallest_team]}) # load new player on host
	update_player_data.rpc(peer_id, {"groups": [smallest_team]}) # load new player on peers
	for connected_players in connected_player_ids: # load existing players on new peer
		update_player_data.rpc_id(peer_id, connected_players, get_player_data(connected_players))
	connected_player_ids.append(peer_id)
	
	player_added.emit(peer_id) # currently only used by leaderboard.gd

func remove_player(peer_id):
	var exiting_player = get_node_or_null(str(peer_id))
	if not exiting_player:
		return
	
	if exiting_player.current_held_flag:
		exiting_player.current_held_flag.return_flag.rpc()
	
	exiting_player.queue_free()

func get_player_data(peer_id):
	var player_node = get_node_or_null(str(peer_id))
	if not player_node:
		return

	return {"groups": player_node.get_groups()}

@rpc
func update_player_data(peer_id, data):
	var player_node = get_node_or_null(str(peer_id))
	if not player_node:
		return
	
	for group in data.groups:
		player_node.add_to_group(group)

	# inits
	var flag_icon: Sprite3D = player_node.get_node("Flag/FlagIcon")
	var plr_mat = player_node.get_node("MeshInstance3D").get_active_material(0).duplicate()
	var flag_color = StandardMaterial3D.new()
	flag_color.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	if player_node.is_in_group("RedTeam"):
		plr_mat.albedo_color = Color(1, 0, 0)
		flag_icon.modulate = Color(0, 0, 1)
		flag_color.albedo_color = Color(0, 0, 1)
		get_tree().get_nodes_in_group("RedSpawn").pick_random().spawn_player(player_node)
	elif player_node.is_in_group("BlueTeam"):
		plr_mat.albedo_color = Color(0, 0, 1)
		flag_icon.modulate = Color(1, 0, 0)
		flag_color.albedo_color = Color(1, 0, 0)
		get_tree().get_nodes_in_group("BlueSpawn").pick_random().spawn_player(player_node)
	else:
		print("player %s has not been assigned a team" % peer_id)
	
	player_node.get_node("MeshInstance3D").set_surface_override_material(0, plr_mat)
	player_node.get_node("Flag/FlagMesh").set_surface_override_material(0, flag_color)
	

@rpc
func remove_player_data(peer_id):
	pass
