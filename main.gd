extends Node2D
## CRATE PUSH — push every crate onto a gold plate.
## Title screen -> level select -> play. Stars for finishing at or near par. Progress is saved.
##
## Controls: Arrows/WASD move (hold to repeat), Z undo, R restart, Esc back to levels.
## Level legend:  # wall   . plate   $ crate   * crate on plate   @ player   + player on plate

const CELL := 32
const VIEW := Vector2(480, 272)
const PA := "res://assets/pixel_adventure_1/Free/"
const HERO := "Virtual Guy" # also: "Ninja Frog", "Mask Dude", "Pink Man"
const WALL_TILE := Vector2i(18, 5)
const PLATE_TILE := Vector2i(17, 9)
const MOVE_TIME := 0.085
const REPEAT_DELAY := 0.22
const REPEAT_RATE := 0.1
const SAVE_PATH := "user://save.cfg"

# [layout, par] — every level was checked with a solver; par = fewest possible moves.
const LEVELS := [
	["#######\n#@ $ .#\n#######", 3],
	["########\n#  .   #\n# $$   #\n#@  .  #\n########", 9],
	["#######\n#. .  #\n# $$# #\n#  @  #\n## $ ##\n #  . #\n ######", 11],
	["  ####\n###  #\n#. $ ##\n#. $@ #\n#. $  #\n#######", 13],
	["#########\n#   #   #\n# $ . $ #\n#   *   #\n# . $ . #\n#   @   #\n#########", 18],
	["  #####\n###   #\n# $ # #\n# .@$ #\n## .  #\n #####", 20],
	[" ######\n##  . #\n# $#  #\n#  $ ##\n#.@ $ #\n## .  #\n ######", 20],
	["#######\n#     #\n# #$# #\n# .@. #\n#  $  #\n#     #\n#######", 22],
	["##########\n#  .  .  #\n# $##$## #\n#   @  $ #\n# $##.## #\n#  .     #\n##########", 46],
	[" #######\n #  .  #\n##$#$# #\n#  .@  #\n# $#.# #\n#      #\n########", 49],
]

enum Screen { TITLE, SELECT, PLAY }

var screen: Screen = Screen.TITLE
var level := 0
var cursor := 0
var best := {} # level index -> best move count
var walls := {}
var plates := {}
var floor_cells := {}
var boxes: Array[Vector2i] = []
var player_cell := Vector2i.ZERO
var moves := 0
var history: Array = []
var origin := Vector2.ZERO
var busy := false
var won := false
var held_dir := Vector2i.ZERO
var repeat_t := 0.0
var queued_dir := Vector2i.ZERO
var t := 0.0

var terrain: Texture2D
var floor_tex: Texture2D
var crate_tex: Texture2D
var crate_done_tex: Texture2D
var dust_tex: Texture2D
var confetti_tex: Texture2D
var hero: AnimatedSprite2D
var crate_sprites: Array[Sprite2D] = []
var ui: Control
var fade: ColorRect
var font: Font
var bg_rect: TextureRect


func _ready() -> void:
	terrain = load(PA + "Terrain/Terrain (16x16).png")
	floor_tex = load(PA + "Background/Brown.png")
	crate_tex = load(PA + "Items/Boxes/Box1/Idle.png")
	crate_done_tex = load(PA + "Items/Boxes/Box3/Idle.png")
	dust_tex = load(PA + "Other/Dust Particle.png")
	confetti_tex = load(PA + "Other/Confetti (16x16).png")
	font = load("res://assets/fonts/PressStart2P-Regular.ttf")

	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := TextureRect.new()
	bg.texture = load(PA + "Background/Purple.png")
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.size = VIEW + Vector2(64, 64)
	bg_layer.add_child(bg)
	bg_rect = bg

	hero = AnimatedSprite2D.new()
	var sf := SpriteFrames.new()
	sf.remove_animation(&"default")
	_add_strip(sf, &"idle", PA + "Main Characters/" + HERO + "/Idle (32x32).png", 20.0, true)
	_add_strip(sf, &"run", PA + "Main Characters/" + HERO + "/Run (32x32).png", 24.0, true)
	_add_strip(sf, &"jump", PA + "Main Characters/" + HERO + "/Double Jump (32x32).png", 18.0, true)
	hero.sprite_frames = sf
	hero.z_index = 3
	hero.play("idle")
	add_child(hero)

	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.size = VIEW
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.draw.connect(_draw_ui)
	layer.add_child(ui)
	fade = ColorRect.new()
	fade.size = VIEW
	fade.color = Color(0.08, 0.05, 0.12, 0.0)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(fade)

	_load_save()
	_show_title()


func _add_strip(sf: SpriteFrames, anim: StringName, path: String, fps: float, loop: bool) -> void:
	var tex: Texture2D = load(path)
	sf.add_animation(anim)
	sf.set_animation_speed(anim, fps)
	sf.set_animation_loop(anim, loop)
	for i in floori(tex.get_width() / 32.0):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * 32, 0, 32, 32)
		sf.add_frame(anim, at)


# ================================================================ save data

func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		for k in cfg.get_section_keys("best") if cfg.has_section("best") else []:
			best[int(k)] = int(cfg.get_value("best", k))


func _save() -> void:
	var cfg := ConfigFile.new()
	for k in best:
		cfg.set_value("best", str(k), best[k])
	cfg.save(SAVE_PATH)


func _stars_for(n: int, move_count: int) -> int:
	var par: int = LEVELS[n][1]
	if move_count <= par:
		return 3
	if move_count <= ceili(par * 1.5):
		return 2
	return 1


func _unlocked(n: int) -> bool:
	return n == 0 or best.has(n - 1)


# ================================================================ screens

func _show_title() -> void:
	screen = Screen.TITLE
	_clear_board()
	hero.visible = true
	hero.position = Vector2(VIEW.x / 2, 150)
	hero.play("idle")


func _show_select() -> void:
	screen = Screen.SELECT
	_clear_board()
	hero.visible = false
	cursor = clampi(cursor, 0, LEVELS.size() - 1)


func _clear_board() -> void:
	walls.clear()
	plates.clear()
	floor_cells.clear()
	boxes.clear()
	for s in crate_sprites:
		s.queue_free()
	crate_sprites.clear()
	queue_redraw()


func _transition(then: Callable) -> void:
	var tw := create_tween()
	tw.tween_property(fade, "color:a", 1.0, 0.15)
	tw.tween_callback(then)
	tw.tween_property(fade, "color:a", 0.0, 0.2)


func _start_level(n: int) -> void:
	screen = Screen.PLAY
	level = n
	won = false
	busy = false
	queued_dir = Vector2i.ZERO
	_clear_board()
	history.clear()
	moves = 0
	var rows: PackedStringArray = (LEVELS[n][0] as String).split("\n")
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
				plates[cell] = true
			if c in "$*":
				boxes.append(cell)
			if c in "@+":
				player_cell = cell
	_fill_floor()
	origin = ((VIEW - Vector2(w, rows.size()) * CELL) / 2.0).floor() + Vector2(0, 2)
	for b in boxes:
		var s := Sprite2D.new()
		s.z_index = 2
		add_child(s)
		crate_sprites.append(s)
	hero.visible = true
	hero.play("idle")
	_snap_sprites()
	queue_redraw()


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
		crate_sprites[i].position = _cell_pos(boxes[i])
		crate_sprites[i].scale = Vector2.ONE
	_update_crates(false)


func _update_crates(pop: bool) -> void:
	for i in boxes.size():
		var on := plates.has(boxes[i])
		var s := crate_sprites[i]
		var tex := crate_done_tex if on else crate_tex
		if pop and on and s.texture != crate_done_tex:
			var tw := s.create_tween()
			tw.tween_property(s, "scale", Vector2(1.3, 1.3), 0.06)
			tw.tween_property(s, "scale", Vector2.ONE, 0.1)
			_sparkle(s.position)
		s.texture = tex


# ================================================================ input

func _dir_for(key: Key) -> Vector2i:
	match key:
		KEY_LEFT, KEY_A:
			return Vector2i.LEFT
		KEY_RIGHT, KEY_D:
			return Vector2i.RIGHT
		KEY_UP, KEY_W:
			return Vector2i.UP
		KEY_DOWN, KEY_S:
			return Vector2i.DOWN
	return Vector2i.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		_on_click((event as InputEventMouseButton).position)
		return
	var key := event as InputEventKey
	if key == null:
		return
	var dir := _dir_for(key.physical_keycode)
	if not key.pressed:
		if dir == held_dir:
			held_dir = Vector2i.ZERO
		return
	if key.echo:
		return
	var confirm := key.physical_keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]
	match screen:
		Screen.TITLE:
			if confirm:
				_transition(_show_select)
		Screen.SELECT:
			if dir != Vector2i.ZERO:
				var nc := cursor + dir.x + dir.y * 5
				if nc >= 0 and nc < LEVELS.size():
					cursor = nc
			elif confirm and _unlocked(cursor):
				_transition(_start_level.bind(cursor))
			elif key.physical_keycode == KEY_ESCAPE:
				_transition(_show_title)
		Screen.PLAY:
			if won:
				if confirm and level < LEVELS.size() - 1:
					cursor = level + 1
					_transition(_start_level.bind(level + 1))
				elif confirm or key.physical_keycode == KEY_ESCAPE:
					cursor = level
					_transition(_show_select)
				elif key.physical_keycode == KEY_R:
					_transition(_start_level.bind(level))
				return
			if dir != Vector2i.ZERO:
				held_dir = dir
				repeat_t = REPEAT_DELAY
				_request_move(dir)
			match key.physical_keycode:
				KEY_Z:
					_undo()
				KEY_R:
					_transition(_start_level.bind(level))
				KEY_ESCAPE:
					cursor = level
					_transition(_show_select)


func _on_click(pos: Vector2) -> void:
	# Mouse works on the title and level select screens.
	var p := ui.get_global_transform_with_canvas().affine_inverse() * pos
	if screen == Screen.TITLE:
		_transition(_show_select)
	elif screen == Screen.SELECT:
		for i in LEVELS.size():
			if _select_rect(i).has_point(p) and _unlocked(i):
				cursor = i
				_transition(_start_level.bind(i))


func _request_move(dir: Vector2i) -> void:
	if busy:
		queued_dir = dir
	else:
		_try_move(dir)


func _process(delta: float) -> void:
	t += delta
	bg_rect.position = Vector2(-fposmod(t * 12.0, 64.0), -fposmod(t * 12.0, 64.0)) # slow scrolling backdrop
	if screen == Screen.PLAY and held_dir != Vector2i.ZERO and not won:
		repeat_t -= delta
		if repeat_t <= 0.0:
			repeat_t = REPEAT_RATE
			_request_move(held_dir)
	ui.queue_redraw()


# ================================================================ moves

func _try_move(dir: Vector2i) -> void:
	if won:
		return
	if dir.x != 0:
		hero.flip_h = dir.x < 0
	var next := player_cell + dir
	if walls.has(next):
		_bump(dir)
		return
	var bi := boxes.find(next)
	if bi >= 0:
		var beyond := next + dir
		if walls.has(beyond) or boxes.has(beyond):
			_bump(dir)
			return
		history.append([player_cell, boxes.duplicate()])
		boxes[bi] = beyond
		var s := crate_sprites[bi]
		var tw := s.create_tween()
		tw.tween_property(s, "position", _cell_pos(beyond), MOVE_TIME)
		var squash := Vector2(0.85, 1.12) if dir.x != 0 else Vector2(1.12, 0.85)
		s.scale = squash
		s.create_tween().tween_property(s, "scale", Vector2.ONE, MOVE_TIME * 1.6)
	else:
		history.append([player_cell, boxes.duplicate()])
	_dust(_cell_pos(player_cell) + Vector2(0, 12))
	player_cell = next
	moves += 1
	busy = true
	hero.play("run")
	var htw := hero.create_tween()
	htw.tween_property(hero, "position", _cell_pos(next), MOVE_TIME)
	htw.finished.connect(_on_move_done)


func _on_move_done() -> void:
	busy = false
	_update_crates(true)
	_check_win()
	if won:
		return
	if queued_dir != Vector2i.ZERO:
		var d := queued_dir
		queued_dir = Vector2i.ZERO
		_try_move(d)
	elif held_dir == Vector2i.ZERO:
		hero.play("idle")


func _bump(dir: Vector2i) -> void:
	if busy:
		return
	busy = true
	var home := _cell_pos(player_cell)
	var tw := hero.create_tween()
	tw.tween_property(hero, "position", home + Vector2(dir) * 4.0, 0.04)
	tw.tween_property(hero, "position", home, 0.06)
	tw.finished.connect(func() -> void:
		busy = false
	)


func _undo() -> void:
	if busy or history.is_empty() or won:
		return
	var h: Array = history.pop_back()
	player_cell = h[0]
	boxes.assign(h[1])
	moves = maxi(moves - 1, 0)
	_snap_sprites()


func _check_win() -> void:
	for b in boxes:
		if not plates.has(b):
			return
	won = true
	held_dir = Vector2i.ZERO
	hero.play("jump")
	if not best.has(level) or moves < int(best[level]):
		best[level] = moves
		_save()
	_confetti()


# ================================================================ effects

func _dust(at: Vector2) -> void:
	var p := CPUParticles2D.new()
	p.texture = dust_tex
	p.position = at
	p.z_index = 1
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 3
	p.lifetime = 0.35
	p.spread = 60.0
	p.direction = Vector2.UP
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 10.0
	p.initial_velocity_max = 25.0
	p.scale_amount_min = 0.4
	p.scale_amount_max = 0.7
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.8))
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	add_child(p)
	p.emitting = true
	get_tree().create_timer(0.6).timeout.connect(p.queue_free)


func _sparkle(at: Vector2) -> void:
	var p := CPUParticles2D.new()
	p.position = at
	p.z_index = 4
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 10
	p.lifetime = 0.45
	p.spread = 180.0
	p.gravity = Vector2(0, 120)
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 80.0
	p.scale_amount_min = 1.5
	p.scale_amount_max = 2.5
	p.color = Color(1, 0.88, 0.35)
	add_child(p)
	p.emitting = true
	get_tree().create_timer(0.8).timeout.connect(p.queue_free)


func _confetti() -> void:
	for i in 6:
		var p := CPUParticles2D.new()
		var at := AtlasTexture.new()
		at.atlas = confetti_tex
		at.region = Rect2(i * 16, 0, 16, 16)
		p.texture = at
		p.position = Vector2(randf_range(40, VIEW.x - 40), -10)
		p.z_index = 10
		p.one_shot = true
		p.explosiveness = 0.6
		p.amount = 10
		p.lifetime = 1.6
		p.direction = Vector2.DOWN
		p.spread = 40.0
		p.gravity = Vector2(0, 140)
		p.initial_velocity_min = 40.0
		p.initial_velocity_max = 110.0
		p.angular_velocity_min = -360.0
		p.angular_velocity_max = 360.0
		p.scale_amount_min = 0.5
		p.scale_amount_max = 0.8
		add_child(p)
		p.emitting = true
		get_tree().create_timer(2.0).timeout.connect(p.queue_free)


# ================================================================ drawing

func _draw() -> void:
	if screen != Screen.PLAY:
		return
	for c: Vector2i in floor_cells:
		var p := origin + Vector2(c) * CELL
		draw_texture_rect_region(floor_tex, Rect2(p, Vector2(CELL, CELL)), Rect2(Vector2(c % 2) * 32, Vector2(32, 32)))
	for c: Vector2i in plates:
		draw_texture_rect_region(terrain, Rect2(origin + Vector2(c) * CELL + Vector2(4, 4), Vector2(24, 24)), Rect2(Vector2(PLATE_TILE * 16), Vector2(16, 16)))
	for c: Vector2i in walls:
		draw_texture_rect_region(terrain, Rect2(origin + Vector2(c) * CELL, Vector2(CELL, CELL)), Rect2(Vector2(WALL_TILE * 16), Vector2(16, 16)))


func _text(s: String, pos: Vector2, size: int, color: Color, width: float = -1.0, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	ui.draw_string_outline(font, pos, s, align, width, size, 4, Color(0.1, 0.05, 0.12))
	ui.draw_string(font, pos, s, align, width, size, color)


func _star(center: Vector2, r: float, filled: bool) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2 + i * PI / 5
		pts.append(center + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	ui.draw_colored_polygon(pts, Color(1, 0.82, 0.25) if filled else Color(0.25, 0.2, 0.3))
	pts.append(pts[0])
	ui.draw_polyline(pts, Color(0.1, 0.05, 0.12), 1.5)


func _select_rect(i: int) -> Rect2:
	return Rect2(60 + (i % 5) * 76, 86 + int(i / 5.0) * 84, 64, 64)


func _draw_ui() -> void:
	var gold := Color(1, 0.82, 0.3)
	match screen:
		Screen.TITLE:
			var bob := sin(t * 2.5) * 3.0
			_text("CRATE PUSH", Vector2(0, 92 + bob), 28, gold, VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
			_text("Push every crate onto a gold plate", Vector2(0, 118), 8, Color.WHITE, VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
			if int(t * 2.0) % 2 == 0:
				_text("Press SPACE to play", Vector2(0, 220), 10, gold, VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
			var total := 0
			for k in best:
				total += _stars_for(k, best[k])
			_text("Stars: %d / %d" % [total, LEVELS.size() * 3], Vector2(0, 252), 8, Color(0.85, 0.85, 1), VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
		Screen.SELECT:
			_text("CHOOSE A LEVEL", Vector2(0, 50), 18, gold, VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
			for i in LEVELS.size():
				var r := _select_rect(i)
				var open := _unlocked(i)
				var fill := Color(0.35, 0.25, 0.5) if open else Color(0.2, 0.17, 0.25)
				if i == cursor:
					fill = fill.lightened(0.25)
				ui.draw_rect(r, fill)
				ui.draw_rect(r, gold if i == cursor else Color(0.1, 0.05, 0.12), false, 3.0 if i == cursor else 2.0)
				_text(str(i + 1) if open else "?", r.position + Vector2(0, 36), 16, Color.WHITE if open else Color(0.5, 0.45, 0.55), r.size.x, HORIZONTAL_ALIGNMENT_CENTER)
				var stars := _stars_for(i, best[i]) if best.has(i) else 0
				for s in 3:
					_star(r.position + Vector2(16 + s * 16, 52), 6.0, s < stars)
			_text("Arrows choose   SPACE play   Esc back", Vector2(0, 262), 8, Color(0.85, 0.85, 1), VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
		Screen.PLAY:
			_text("LEVEL %d" % (level + 1), Vector2(8, 20), 10, gold)
			_text("Moves %d" % moves, Vector2(0, 20), 10, Color.WHITE, VIEW.x - 8, HORIZONTAL_ALIGNMENT_RIGHT)
			_text("Z undo   R restart   Esc levels", Vector2(0, 268), 8, Color(0.85, 0.85, 1), VIEW.x, HORIZONTAL_ALIGNMENT_CENTER)
			if won:
				var panel := Rect2(110, 82, 260, 120)
				ui.draw_rect(panel, Color(0.12, 0.08, 0.18, 0.92))
				ui.draw_rect(panel, gold, false, 3.0)
				_text("LEVEL CLEAR!", panel.position + Vector2(0, 32), 16, gold, panel.size.x, HORIZONTAL_ALIGNMENT_CENTER)
				var stars := _stars_for(level, moves)
				for s in 3:
					_star(panel.position + Vector2(100 + s * 30, 56), 11.0, s < stars)
				_text("%d moves" % moves, panel.position + Vector2(0, 90), 10, Color.WHITE, panel.size.x, HORIZONTAL_ALIGNMENT_CENTER)
				var next := "SPACE next level" if level < LEVELS.size() - 1 else "SPACE back to levels"
				_text(next + "   R retry", panel.position + Vector2(0, 110), 8, Color(0.85, 0.85, 1), panel.size.x, HORIZONTAL_ALIGNMENT_CENTER)
