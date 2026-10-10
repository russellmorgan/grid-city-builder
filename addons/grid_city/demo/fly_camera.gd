extends Camera3D

## Demo camera: hold right mouse (or move the right stick) to look around,
## WASD / left stick to fly, Q/E or triggers for down/up, Shift to go fast.

@export var speed := 40.0
@export var look_sensitivity := 0.003

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)


func _process(delta: float) -> void:
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.15:
		_yaw -= stick.x * delta * 2.0
		_pitch = clampf(_pitch - stick.y * delta * 2.0, -1.5, 1.5)
	rotation = Vector3(_pitch, _yaw, 0)
	var move := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)) + Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
			+ Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) - Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)) + Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if move.length() < 0.15:
		return
	var fast := 4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	position += global_basis * move.limit_length(1.0) * speed * fast * delta
