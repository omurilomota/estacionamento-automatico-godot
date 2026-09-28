class_name VehicleCatalog
extends RefCounted
## The selectable cars — a SKIN menu, not a physics menu.
##
## Two art families ship in the repo: the 5 Kenney `car_*_5.png` (70x121, the
## car fills the whole texture) and the 5 `assets/sprites/*.png` (100x100 with
## the car in a sub-rect). They have different pixel sizes AND different aspect
## ratios, so "same model at the same size" no longer holds literally.
##
## The invariant that DOES hold — and the one `scenes/Carro.tscn`'s
## `scale = 1.62` plus the 88x74 collision box actually need — is that every
## skin is drawn inside the SAME visual box (70x121 px before the child's 1.62),
## centred on the node origin. `apply()` enforces it with a per-entry region:
##   drawn = region.size * scale = TARGET * SPRITE_BASE_SCALE   for every skin.
## ModulesCheck asserts that product for all 10, so a new skin with a different
## texture size can never silently change the car's on-screen footprint.
##
## The choice lives in a `static var`: a GDScript static survives
## `change_scene_to_file()`, so switching levels keeps the car without an
## autoload or a `user://` file.

## Visual box the collision box is calibrated against (local px, nose -Y).
const TARGET := Vector2(70.0, 121.0)
## The child Sprite2D's scale in `scenes/Carro.tscn`.
const SPRITE_BASE_SCALE := 1.62

const CARS: Array[Dictionary] = [
	{"id": "blue", "label": "Azul", "path": "res://assets/kenney/cars/car_blue_5.png", "region": Rect2i(0, 0, 70, 121)},
	{"id": "black", "label": "Preto", "path": "res://assets/kenney/cars/car_black_5.png", "region": Rect2i(0, 0, 70, 121)},
	{"id": "green", "label": "Verde", "path": "res://assets/kenney/cars/car_green_5.png", "region": Rect2i(0, 0, 70, 121)},
	{"id": "red", "label": "Vermelho", "path": "res://assets/kenney/cars/car_red_5.png", "region": Rect2i(0, 0, 70, 121)},
	{"id": "yellow", "label": "Amarelo", "path": "res://assets/kenney/cars/car_yellow_5.png", "region": Rect2i(0, 0, 70, 121)},
	# `assets/sprites/*` are 100x100 with the car inside a sub-rect (trimmed to
	# its alpha bounding box), same top-down "-Y is the nose" convention.
	{"id": "sedan", "label": "Sedan vermelho", "path": "res://assets/sprites/sedan_vermelho.png", "region": Rect2i(31, 21, 38, 65)},
	{"id": "suv", "label": "SUV branco", "path": "res://assets/sprites/suv_branco.png", "region": Rect2i(30, 20, 40, 61)},
	{"id": "muscle", "label": "Muscle amarelo", "path": "res://assets/sprites/musclecar_amarelo.png", "region": Rect2i(29, 20, 42, 66)},
	{"id": "taxi", "label": "Taxi", "path": "res://assets/sprites/taxi.png", "region": Rect2i(31, 21, 38, 65)},
	{"id": "classic", "label": "Classico", "path": "res://assets/sprites/carro.png", "region": Rect2i(32, 35, 36, 43)},
]

const DEFAULT_ID := "blue"

static var current_id: String = DEFAULT_ID


## Stable ids, in menu order.
static func ids() -> Array[String]:
	var out: Array[String] = []
	for car in CARS:
		out.append(str(car["id"]))
	return out


static func _entry(id: String) -> Dictionary:
	for car in CARS:
		if str(car["id"]) == id:
			return car
	return {}


## Human label (PT-BR, the one language the player sees).
static func label_for(id: String) -> String:
	return str(_entry(id).get("label", ""))


static func path_for(id: String) -> String:
	return str(_entry(id).get("path", ""))


## Sub-rect of the texture that holds the car (its alpha bounding box).
static func region_for(id: String) -> Rect2i:
	var e := _entry(id)
	return e.get("region", Rect2i())


## Sprite scale that maps THIS entry's region onto the shared visual box, so
## every skin is drawn 113.4 x 196.0 px. The Kenney entries come out at exactly
## `SPRITE_BASE_SCALE`, i.e. unchanged from what the scene already declares.
static func sprite_scale_for(id: String) -> Vector2:
	var r := region_for(id)
	if r.size.x <= 0 or r.size.y <= 0:
		return Vector2(SPRITE_BASE_SCALE, SPRITE_BASE_SCALE)
	return Vector2(TARGET.x / float(r.size.x), TARGET.y / float(r.size.y)) * SPRITE_BASE_SCALE


static func index_of(id: String) -> int:
	var list := ids()
	return list.find(id)


static func id_at(index: int) -> String:
	var list := ids()
	if list.is_empty():
		return DEFAULT_ID
	return list[posmod(index, list.size())]


## Next/previous car, wrapping around. Returns the NEW current id.
static func cycle(step: int = 1) -> String:
	current_id = id_at(index_of(current_id) + step)
	return current_id


static func texture_for(id: String) -> Texture2D:
	var path := path_for(id)
	if path.is_empty():
		return null
	return load(path) as Texture2D


## Swaps the vehicle's skin. `sprite_path` is the vehicle's exported NodePath
## (defaults to "Sprite2D"); the node does not need to be in a scene tree, so
## this is unit-testable headless. Returns false when the id is unknown or the
## sprite node is missing.
static func apply(vehicle: Node, id: String) -> bool:
	if vehicle == null or not is_instance_valid(vehicle):
		return false
	var tex := texture_for(id)
	if tex == null:
		return false
	var sprite: Sprite2D = null
	if "sprite_path" in vehicle and not str(vehicle.get("sprite_path")).is_empty():
		sprite = vehicle.get_node_or_null(vehicle.get("sprite_path")) as Sprite2D
	if sprite == null:
		sprite = vehicle.get_node_or_null("Sprite2D") as Sprite2D
	if sprite == null:
		return false
	var region := region_for(id)
	if region.size.x <= 0 or region.size.y <= 0:
		region = Rect2i(Vector2i.ZERO, tex.get_size())
	sprite.texture = tex
	sprite.region_enabled = true
	sprite.region_rect = Rect2(region)
	sprite.scale = sprite_scale_for(id)
	current_id = id
	return true
