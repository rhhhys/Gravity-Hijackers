extends CharacterBody3D

#Signals:
signal health_changed(health_value)

#Assets
@onready var camera = $Camera3D
@onready var anim_player = $AnimationPlayer
@onready var muzzle_flash = $Camera3D/Pistol/MuzzleFlash
@onready var raycast = $Camera3D/RayCast3D
@onready var camera_3d: Camera3D = $Camera3D
@onready var crosshair = Global.worldNode.hud.get_node("Crosshair")
@onready var ammo_display = Global.worldNode.hud.get_node("AmmoDisplay")
@onready var grav_slider = Global.worldNode.hud.get_node("GravitySlider")
@onready var flip_cd_label = Global.worldNode.hud.get_node("FlipCooldownLabel")
@onready var grav_flip_timer = $GravFlipTimer

#Preloads
@onready var damage_billboard = preload("res://scenes/DamageIndicator.tscn")
@onready var hit_marker = preload("res://scenes/HitMarker.tscn")
@onready var player_scene = preload("res://scenes/player.tscn")
@onready var world_scene = preload("res://scenes/environment.tscn")
@onready var speed_pickup_scene = preload("res://scenes/speed_pickup.tscn")

#Pickups
@onready var default_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
@onready var speed_pickup_scene_instantiated = get_parent().get_node("Speed_Pickup")
@onready var speed_pickup_multiplier = 1

#Crouching
@export var ANIMATIONPLAYER : AnimationPlayer
@export var CROUCH_SPEED : float = 0
@export var is_crouching: bool = false

#Instantiation
@onready var player_scene_instantiated = player_scene.instantiate()
@onready var world_scene_instantiated = world_scene.instantiate()

#Stats
var health = 10
var ammo_count = 15
var bullet_damage = 2
var SPEED = 5.5
var JUMP_VELOCITY = 10
var gravity_strengths = [3, 1.5, 0.75, 0.375]
var gravity_direction = 1

#MISC
@export var X_mouse_sensitivity = 0.01
@export var Y_mouse_sensitivity = 0.01
var reloading = false
const LOOK_SPEED = 5 #Existed since the begginning, Charles is scared to remove it


func _enter_tree(): #Starts the game, gives multiplayer authority for your controls
	set_multiplayer_authority(str(name).to_int())

func _ready(): #Plays on first entering the game
	speed_pickup_scene_instantiated.speed_pickup_pickedup.connect(_on_speed_pickup_pickedup) #WIP, TALK TO JAYDAN
	if not is_multiplayer_authority(): return
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED #Allows you to move camera
	camera.current = true

func _exit_tree() -> void: #for when you leave the actual game for the main menu (Can't actually do this yet)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event):
	if not is_multiplayer_authority(): return
	
	if event is InputEventMouseMotion: #Allows you to move mouse in game
		rotate_object_local(Vector3.UP, -event.relative.x * X_mouse_sensitivity) # left right
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * Y_mouse_sensitivity) # up down
		camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)
	
	if Input.is_action_just_pressed("decrease_gravity") and event.is_pressed(): # check if pressed so scrolls dont fire twice
		grav_slider.value -= 1
	
	if Input.is_action_just_pressed("increase_gravity") and event.is_pressed():
		grav_slider.value += 1
	
	if Input.is_action_just_pressed("reload") and !reloading and anim_player.current_animation != "shoot":
		upd_ammo(0, true) # call reload update
	
	#ALL SHOOTING STUFF, IT WORKS, DO NOT CHANGE IT UNLESS RHYS
	if Input.is_action_just_pressed("shoot") and anim_player.current_animation != "shoot" and ammo_count > 0:
		upd_ammo(-1)
		play_shoot_effects.rpc()
		
		if raycast.is_colliding():
			var hit_obj = raycast.get_collider()
			var hit_coords = raycast.get_collision_point()
			var relative_hit_coords = hit_coords - hit_obj.position # relative to the colliding object
			var headshot = true if relative_hit_coords.y >= 1.4 else false # above 1.4 is roughly where the player's head is
			# avoid nesting, also prevents friendly fire
			if !hit_obj.is_in_group("Player") and !hit_obj.is_in_group("enemy") or get_groups() == hit_obj.get_groups():
				return
			
			# instance new client side hitmarker gui
			var new_hit_marker = hit_marker.instantiate()
			Global.worldNode.get_node("CanvasLayer/HUD").add_child(new_hit_marker)
			new_hit_marker.position = Vector2(
				crosshair.position.x - (new_hit_marker.size.x / 2), 
				crosshair.position.y - (new_hit_marker.size.y / 2)
			)
			new_hit_marker.scale = Vector2(0.5, 0.5)
			# instance new damage count billboard gui where ray collides
			var new_damage_billboard = damage_billboard.instantiate()
			var billboard_label = new_damage_billboard.get_node("Label3D") 
			Global.worldNode.add_child(new_damage_billboard)
			new_damage_billboard.position = Vector3(hit_coords)
			if headshot:
				billboard_label.text = str(-bullet_damage*2)
				billboard_label.modulate = Color("e10006")
				billboard_label.outline_modulate = Color("400000")
			else: 
				billboard_label.text = str(-bullet_damage)
			#print(new_damage_billboard.position, new_damage_billboard.get_parent())
			
			# damage player only (enemy has no receive damage method)
			if hit_obj in get_tree().get_nodes_in_group("Player"):
				hit_obj.receive_damage.rpc_id(hit_obj.get_multiplayer_authority(), headshot) # pass bool as arg for headshot

func _physics_process(delta): #Occurs every delta frame
	speed_pickup_scene_instantiated = get_parent().get_node("Speed_Pickup") #Speed Changing, WIP: TALK TO JAYDAN
	if not is_multiplayer_authority(): return
	
	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	#MOVEMENT AND CONTROLS
	move_and_slide()
	
	var input_dir = Input.get_vector("left", "right", "up", "down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	
	#JUMPING AND GRAVITY
	if Input.is_action_just_pressed("flip_gravity") and grav_flip_timer.time_left == 0:
		gravity_direction = -gravity_direction
		grav_flip_timer.start()
		# instant flip mechannics
		#rotate_z(PI) # flip
		#rotation.y = -rotation.y # correct flip reversal
		#camera.rotation.x = -camera.rotation.x # correct flip reversal
		#position -= Vector3(0, 2*gravity_direction, 0) # keep player pos after instant flip
	rotation.z = lerp_angle(rotation.z, PI if gravity_direction == -1 else 0, 5*delta)
	if grav_flip_timer.time_left == 0:
		flip_cd_label.text = ""
	else:
		flip_cd_label.text = "CD %.2fs" % grav_flip_timer.time_left
	
	if (not is_on_floor() and gravity_direction == 1) or (not is_on_ceiling() and gravity_direction == -1):
		velocity.y -= default_gravity * gravity_direction * gravity_strengths[int(grav_slider.value)] * delta
	
	if Input.is_action_just_pressed("player_jump") and (is_on_floor() or is_on_ceiling()):
		velocity.y = JUMP_VELOCITY if is_on_floor() else -JUMP_VELOCITY if is_on_ceiling() else int(velocity.y) # wrap velocity.y in int to get ternary warnings to pipe down

	#SPRINTING AND CROUCHING
	if Input.is_action_pressed("player_sprint"):
		SPEED = 8 * speed_pickup_multiplier
	else:
		SPEED = 5.5 * speed_pickup_multiplier
	
	if Input.is_action_just_pressed("player_crouch"):
		if !is_multiplayer_authority():
			return
		crouch.rpc()



	# THIS WAS DONE AT THE TEMPLATE AND CHARLES IS TOO SCARED TO REMOVE IT
	var look_dir = Input.get_vector("look_left", "look_right", "look_up", "look_down") # SUPPOSED CONTROLLER SENSITIVITY STUFF
	if look_dir != Vector2.ZERO:
		# Rotate Player (Yaw) - Horizontal movement of the stick
		rotate_y(-look_dir.x * LOOK_SPEED * delta)
		
		# Rotate Camera (Pitch) - Vertical movement of the stick
		camera.rotate_x(-look_dir.y * LOOK_SPEED * delta)
		
		# Clamp camera pitch rotation (same as your mouse look code)
		camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)

	#Settings stuff
	_on_fov_updated(Save.game_data["FOV"])
	_X_on_mouse_sens_updated(Save.game_data["X_Mouse_sens_Multi"])
	_Y_on_mouse_sens_updated(Save.game_data["Y_Mouse_sens_Multi"])
	
	#Shoot animation
	if anim_player.current_animation == "shoot": 
		pass
	elif anim_player.current_animation in ["Crouch", "Uncrouch"]:
		pass
	elif input_dir != Vector2.ZERO and is_on_floor():
		anim_player.play("move")
	else:
		anim_player.play("idle")

#ANIMATION FUNCTIONS
@rpc("call_local")
func crouch():
	#print(is_crouching)
	#print($".".name)
	if is_crouching == true:
		#print("Crouch2")
		anim_player.play("Uncrouch")
		is_crouching = false

	elif is_crouching == false:
		#print("Crouch1")
		anim_player.play("Crouch")
		is_crouching = true


func _on_animation_player_animation_finished(anim_name):
	if anim_name == "shoot":
		anim_player.play("idle")
		
#MULTIPLAYER STUFF
@rpc("call_local")
func play_shoot_effects():
	anim_player.stop()
	anim_player.play("shoot")
	$AudioStreamPlayer3D.play()
	muzzle_flash.restart()
	muzzle_flash.emitting = true

@rpc("any_peer")
func receive_damage(headshot: bool):
	health -= bullet_damage*2 if headshot else bullet_damage
	if health <= 0:
		health = 10
		position = Vector3.ZERO
	health_changed.emit(health)

#SETTINGS FUNCTIONS
func _on_fov_updated(value):
	if not is_multiplayer_authority(): return
	#print(Save.game_data["FOV"])
	camera.fov = value
func _X_on_mouse_sens_updated(value):
	if not is_multiplayer_authority(): return
	X_mouse_sensitivity = value
func _Y_on_mouse_sens_updated(value):
	if not is_multiplayer_authority(): return
	Y_mouse_sensitivity = value

#MISCELLANEOUS
func upd_ammo(num: int, reload: bool = false):
	if reload:
		reloading = true
		crosshair.hide()
		await get_tree().create_timer(1).timeout
		crosshair.show()
		ammo_count = 15
		reloading = false
	else:
		ammo_count += num
	ammo_display.text = "%d / 15" % ammo_count

func _on_speed_pickup_pickedup(value):
	print("SPEED_PICKUP")
	speed_pickup_multiplier = value
