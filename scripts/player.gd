# Player.gd
extends CharacterBody2D

var move_speed: float = 400.0
var accel: float = 2100.0
var gravity: float = 1900.0
var jump_force: float = 900.0

@onready var camera_2d: Camera2D = $Camera2D

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	camera_2d.enabled = true
	_handle_gravity(delta)
	_handle_input(delta)

	move_and_slide()

func _handle_gravity(delta) -> void:
	velocity.y += gravity * delta
	
func _handle_input(delta) -> void:
	var input_direction
	if Input.is_action_pressed("click"):
		if get_global_mouse_position().y > global_position.y:
			if get_global_mouse_position().x > global_position.x:
				input_direction = 1
			else:
				input_direction = -1
		else:
			_handle_jumping()
	else:
		input_direction = Input.get_axis("left", "right")
	if input_direction:
		velocity.x = move_toward(velocity.x, input_direction * move_speed, accel * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, accel * delta)
	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			_handle_jumping()

func _handle_jumping() -> void:
	if is_on_floor():
		velocity.y = - jump_force
