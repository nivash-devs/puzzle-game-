extends Node2D
## BOX PUSHER — push every crate onto a gold plate.
## Arrows/WASD move, Z undo, R restart level, Space next level.
##
## Level legend:  # wall   . target   $ box   * box on target   @ player   + player on target

const CELL := 32
const VIEW := Vector2(480, 272)
const PA := "res://assets/pixel_adventure_1/Free/"
const HERO := "Virtual Guy" # also: "Ninja Frog", "Mask Dude", "Pink Man"
const WALL_TILE := Vector2i(18, 5) # red brick in Terrain (16x16).png
const TARGET_TILE := Vector2i(17, 9) # gold plate
const MOVE_TIME := 0.09

const LEVELS := [
	"#######\n#@ $ .#\n#######",
	"########\n#  .   #\n# $$   #\n#@  .  #\n########",
	"  #####\n###   #\n# $ # #\n# .@$ #\n## .  #\n #####",
	"#######\n#. .  #\n# $$# #\n#  @  #\n## $ ##\n #  . #\n ######",
	" ######\n##  . #\n# $#  #\n#  $ ##\n#.@ $ #\n## .  #\n ######",
]

var level := 0
var walls := {}
var targets := {}
var floor_cells := {}
var boxes: Array[Vector2i] = []
var player_cell := Vector2i.ZERO
var moves := 0
var history: Array = []
var origin := Vector2.ZERO
var busy := false
var won := false

var terrain: Texture2D
var floor_tex: Texture2D
var box_tex: Texture2D
var hero: AnimatedSprite2D
var box_sprites: Array[Sprite2D] = []
var hud: Label
var banner: Label


func _ready() -> void:
	terrain = load(PA + "Terrain/Terrain (16x16).png")
	floor_tex = load(PA + "Background/Brown.png")
	box_tex = load(PA + "Items/Boxes/Box1/Idle.png")

	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := TextureRect.new()
	bg.texture = load(PA + "Background/Gray.png")
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.size = VIEW
	bg_layer.add_child(bg)

	hero = AnimatedSprite2D.new()
	var sf := SpriteFrames.new()
	sf.remove_animation(&"default")
	_add_strip(sf, &"idle", PA + "Main Characters/" + HERO + "/Idle (32x32).png", 20.0)
	_add_strip(sf, &"run", PA + "Main Characters/" + HERO + "/Run (32x32).png", 24.0)
	hero.sprite_frames = sf
	hero.play("idle")
	hero.z_index = 2
	add_child(hero)

	var ui := CanvasLayer.new()
	add_child(ui)
	hud = _label(Vector2(6, 4), Vector2(468, 16), HORIZONTAL_ALIGNMENT_LEFT, 8)
	ui.add_child(hud)
	banner = _label(Vector2(0, 236), Vector2(480, 30), HORIZONTAL_ALIGNMENT_CENTER, 16)
	ui.add_child(banner)

	_load_level(0)


func _add_strip(sf: SpriteFrames, anim: StringName, path: String, fps: float) -> void:
	var tex: Texture2D = load(path)
	sf.add_animation(anim)
	sf.set_animation_speed(anim, fps)
	for i in tex.get_width() / 32:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * 32, 0, 32, 32)
		sf.add_frame(anim, at)


func _label(pos: Vector2, size: Vector2, align: HorizontalAlignment, font_size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = size
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0.1))
	l.add_theme_constant_override("outline_size", 4)
	return l


# ---------------------------------------------------------------- levels

func _load_level(n: int) -> void:
	level = n
	won = false
	walls.clear()
	targets.clear()
	floor_cells.clear()
	boxes.clear()
	history.clear()
	moves = 0
	var rows: PackedStringArray = (LEVELS[n] as String).split("\n")
	var w := 0
	for y in rows.size():
		w = maxi(w, rows[y].length())
		for x in rows[y].length():
			var c := rows[y][x]
			var cell := Vector2i(x, y)
			if c == "#":
				walls[cell] = true
				continue
			if c in ".*+":
				targets[cell] = true
			if c in "$*":
				boxes.append(cell)
			if c in "@+":
				player_cell = cell
	_fill_floor()
	origin = ((VIEW - Vector2(w, rows.size()) * CELL) / 2.0).floor()

	for s in box_sprites:
		s.queue_free()
	box_sprites.clear()
	for b in boxes:
		var s := Sprite2D.new()
		s.texture = box_tex
		s.z_index = 1
		add_child(s)
		box_sprites.append(s)
	_snap_sprites()
	banner.text = ""
	_update_hud()
	queue_redraw()


## Floor = every cell reachable from the player without crossing walls.
func _fill_floor() -> void:
	var stack: Array[Vector2i] = [player_cell]
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		if floor_cells.has(c) or walls.has(c) or c.x < 0 or c.y < 0 or c.x > 40 or c.y > 40:
			continue
		floor_cells[c] = true
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			stack.append(c + d)


func _cell_pos(c: Vector2i) -> Vector2:
	return origin + Vector2(c) * CELL + Vector2(CELL, CELL) / 2.0


func _snap_sprites() -> void:
	hero.position = _cell_pos(player_cell)
	for i in boxes.size():
		box_sprites[i].position = _cell_pos(boxes[i])
	_tint_boxes()


func _tint_boxes() -> void:
	for i in boxes.size():
		box_sprites[i].modulate = Color(1.0, 0.85, 0.3) if targets.has(boxes[i]) else Color.WHITE


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.physical_keycode:
		KEY_LEFT, KEY_A:
			_try_move(Vector2i.LEFT)
		KEY_RIGHT, KEY_D:
			_try_move(Vector2i.RIGHT)
		KEY_UP, KEY_W:
			_try_move(Vector2i.UP)
		KEY_DOWN, KEY_S:
			_try_move(Vector2i.DOWN)
		KEY_Z:
			_undo()
		KEY_R:
			_load_level(level)
		KEY_SPACE, KEY_ENTER:
			if won:
				_load_level((level + 1) % LEVELS.size())


func _try_move(dir: Vector2i) -> void:
	if busy or won:
		return
	if dir.x != 0:
		hero.flip_h = dir.x < 0
	var next := player_cell + dir
	if walls.has(next):
		return
	var bi := boxes.find(next)
	if bi >= 0:
		var beyond := next + dir
		if walls.has(beyond) or boxes.has(beyond):
			return
		history.append([player_cell, boxes.duplicate()])
		boxes[bi] = beyond
		_tween(box_sprites[bi], beyond)
	else:
		history.append([player_cell, boxes.duplicate()])
	player_cell = next
	moves += 1
	busy = true
	hero.play("run")
	var tw := _tween(hero, next)
	tw.finished.connect(func() -> void:
		busy = false
		hero.play("idle")
		_tint_boxes()
		_check_win()
	)
	_update_hud()


func _tween(node: Node2D, cell: Vector2i) -> Tween:
	var tw := node.create_tween()
	tw.tween_property(node, "position", _cell_pos(cell), MOVE_TIME)
	return tw


func _undo() -> void:
	if busy or history.is_empty() or won:
		return
	var h: Array = history.pop_back()
	player_cell = h[0]
	boxes.assign(h[1])
	moves = maxi(moves - 1, 0)
	_snap_sprites()
	_update_hud()


func _check_win() -> void:
	for b in boxes:
		if not targets.has(b):
			return
	won = true
	if level == LEVELS.size() - 1:
		banner.text = "YOU BEAT EVERY LEVEL! SPACE to play again"
	else:
		banner.text = "LEVEL CLEAR!  SPACE for next level"
	var tw := create_tween().set_loops(3)
	for s in box_sprites:
		tw.parallel().tween_property(s, "scale", Vector2(1.2, 1.2), 0.1)
	tw.tween_interval(0.0)
	for s in box_sprites:
		tw.parallel().tween_property(s, "scale", Vector2.ONE, 0.1)


func _update_hud() -> void:
	hud.text = "LEVEL %d/%d    MOVES %d        Z undo   R restart" % [level + 1, LEVELS.size(), moves]


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	for c: Vector2i in floor_cells:
		var p := origin + Vector2(c) * CELL
		draw_texture_rect_region(floor_tex, Rect2(p, Vector2(CELL, CELL)), Rect2(Vector2(c % 2) * 32, Vector2(32, 32)))
	for c: Vector2i in targets:
		draw_texture_rect_region(terrain, Rect2(origin + Vector2(c) * CELL + Vector2(4, 4), Vector2(24, 24)), Rect2(Vector2(TARGET_TILE * 16), Vector2(16, 16)))
	for c: Vector2i in walls:
		draw_texture_rect_region(terrain, Rect2(origin + Vector2(c) * CELL, Vector2(CELL, CELL)), Rect2(Vector2(WALL_TILE * 16), Vector2(16, 16)))
