extends GridContainer


const mapsize_x: int = 64;
const mapsize_y: int = 48;

var level_map = null; # null in sandbox mode
var banned_tiles = null;
var initial_map = PoolByteArray(range(mapsize_x * mapsize_y));
var level_requirements = [
	# [X, Y, Z], ... # Solve X seed for Y ticks: has been completed to Z%
];

var current_step: int = 0;
var current_map = null;
var current_changed: PoolByteArray = PoolByteArray(range(mapsize_y * mapsize_x));
var solved_since = null;

var current_tile_selection = "wall";
var last_placed_cell_state = null;
var last_held_mouse_button = 1;

var tick_map_trigger: Semaphore = Semaphore.new();
var tick_map_finish: Semaphore = Semaphore.new();
var tick_map_requested: bool = false;
var tick_map_thread_fn_dead: bool = false;
var tick_map_thread: Thread = Thread.new();

var selection_start = null;
var selection_end = null;
var paste_mode = null;

var last_log_update_time: float = 0;
var last_tick_time: float = 0;

var map_history_position = -1;
var map_history = [];

var tick_seed: String = "";
var tick_seed_position: int = 0;

# The map wraps horizontally, not vertically
func xy(x: int, y: int) -> int:
	return mod(x, mapsize_x) + y * mapsize_x;

func iy(c: int) -> int:
	return c / mapsize_x;

func addxy(c: int, x: int, y: int) -> int:
	return mod(c + x, mapsize_x) + mapsize_x * ((c / mapsize_x) + y);

func mod(a: int, b: int) -> int:
	return ((a % b) + b) % b;


func _exit_tree():
	tick_map_thread_fn_dead = true;
	if tick_map_trigger.post() != OK:
		print("Failed to trigger tick_map");
	tick_map_thread.wait_to_finish();
	save_map("user://autosave.rlvl");


func _ready():
	randomize();
	
	OS.min_window_size = Vector2(200, 150);
	if tick_map_thread.start(self, "tick_map_thread_fn") != OK:
		log_for_user("Failed to start the tick_map thread. This won't work");
	
	set_map_scale(Vector2(1, 1));
	
	_on_SandboxCheckBox_toggled($PanelContainer3/VBoxContainer/SandboxCheckBox.pressed);
	$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow/MarkCompletedButton.disabled = true;
	
	if Global.playing_campaign_level_with_path == null:
		if load_map("user://autosave.rlvl"):
			log_for_user("Failed to load autosave");
			var map = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap;
			for x in range(mapsize_x):
				for y in range(mapsize_y):
					map.set_cell(x, y, 0);
					initial_map[xy(x, y)] = 0;
					level_map[xy(x, y)] = 0;
			$PanelContainer3/VBoxContainer/SandboxCheckBox.pressed = true;
		else:
			log_for_user("Loaded autosave");
		$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow.visible = false;
	else:
		var solutionpath = Global.playing_campaign_solution_with_path;
		var levelpath: String = Global.playing_campaign_level_with_path;
		Global.playing_campaign_solution_with_path = null;
		Global.playing_campaign_level_with_path = null;
		if load_map(levelpath):
			print("Failed to load " + levelpath);
		if solutionpath != null:
			if load_map(solutionpath): # TODO check this is valid with levelpath
				print("Failed to load " + solutionpath);
		Global.playing_campaign_level_with_path = levelpath;
		Global.playing_campaign_solution_with_path = solutionpath;
		log_for_user("Loaded level " + levelpath);
		var levelname_parts = levelpath.get_file().get_basename().split("-");
		assert (levelname_parts.size() > 2);
		var level_number = levelname_parts[0] + "." + levelname_parts[1];
		$PanelContainer3/VBoxContainer/CampaignLevelLabel.text = level_number;
		$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow/CampaignLevelLabel2.text = level_number + ": " + levelname_parts.join(" ").right(level_number.length() + 1);
		$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow.visible = true;
	
	push_history();
	
func finish_tick():
	var map = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap;
	var solved: bool = true;
	for yy in range(mapsize_y):
		var y = mapsize_y - yy - 1;
		for x in range(mapsize_x):
			var ind = xy(x, y);
			var c = current_map[ind];
			if c == target_i or c == targetbad_i:
				solved = false;
			map.set_cell(x, y, c);
	
	if solved and solved_since == null:
		solved_since = current_step;
	if not solved:
		solved_since = null;
	if solved_since == null:
		$PanelContainer3/VBoxContainer/SolvedInfoLine.visible = false;
	else:
		$PanelContainer3/VBoxContainer/SolvedInfoLine/SolvedLabel.text = str(solved_since);
		$PanelContainer3/VBoxContainer/SolvedInfoLine.visible = true;
		var s = $PanelContainer3/VBoxContainer/SeedLineEdit.text;
		for i in range(level_requirements.size()):
			var req = level_requirements[i];
			if req[0] == s:
				req[2] = max(req[2], int(100 * min(1, float(current_step - solved_since) / req[1])));
				$PanelContainer4/ScrollContainer/VBoxContainer/LevelRequirements.get_child(i + 1).value = req[2];
	
	$PanelContainer3/VBoxContainer/LoadButton.disabled = true;
	$PanelContainer3/VBoxContainer/SaveButton.disabled = true;
	tick_map_requested = false;


func _process(_delta):
	var now = Time.get_ticks_msec();
	$PanelContainer4/UserLogVBox.visible = now - last_log_update_time < 3000;
	
	if tick_map_finish.try_wait() == OK:
		$PanelContainer3/VBoxContainer/FPSInfoLine2/FPSLabel.text = str(1000 / (now - last_tick_time + 0.1)).pad_decimals(2);
		last_tick_time = now;
		finish_tick();
	
	var can_mark_level_as_completed = true;
	for req in level_requirements:
		if req[2] != 100:
			can_mark_level_as_completed = false
	if can_mark_level_as_completed:
		$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow/MarkCompletedButton.disabled = false;
		$PanelContainer4/ScrollContainer.scroll_vertical = 0;
	
	if $PanelContainer3/VBoxContainer/LoadFileDialog.visible:
		return;
	
	if Input.is_action_just_pressed("reset_map"):
		_on_ResetButton_pressed();
	
	if Input.is_action_just_pressed("Undo") and not Input.is_key_pressed(KEY_SHIFT):
		_on_UndoButton_pressed();
	
	if Input.is_action_just_pressed("Redo"):
		_on_RedoButton_pressed();
	
	var playcheck = $PanelContainer3/VBoxContainer/PlayCheckBox;
	if Input.is_action_just_pressed("toggle_pause"):
		playcheck.pressed = not playcheck.pressed;
	
	if Input.is_action_just_pressed("step_map") or playcheck.pressed:
		do_step();
	
	if current_step == 0:
		if Input.is_action_just_pressed("select_all"):
			set_selection(Vector2(0, 0), Vector2(mapsize_x - 1, mapsize_y - 1));
		
		var map = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap;
		if selection_end != null:
			var sel = get_selection_rect();
			if Input.is_action_just_pressed("copy_selection"):
				OS.clipboard = serialize_map(initial_map, get_selection_rect());
			if Input.is_action_just_pressed("cut_selection"):
				OS.clipboard = serialize_map(initial_map, get_selection_rect());
				for y in range(sel.position.y, sel.end.y):
					for x in range(sel.position.x, sel.end.x):
						set_cell(map, x, y, 0);
				push_history();
			if Input.is_action_just_pressed("select_none"):
				select_none();
			if Input.is_action_just_pressed("clear_selection"):
				for y in range(sel.position.y, sel.end.y):
					for x in range(sel.position.x, sel.end.x):
						set_cell(map, x, y, 0);
				push_history();
			if Input.is_action_just_pressed("fill_selection"):
				for y in range(sel.position.y, sel.end.y):
					for x in range(sel.position.x, sel.end.x):
						set_cell(map, x, y, CELLS[current_tile_selection].state);
				push_history();
			if Input.is_action_just_pressed("fill_selection_empties"):
				for y in range(sel.position.y, sel.end.y):
					for x in range(sel.position.x, sel.end.x):
						if initial_map[xy(x, y)] == 0:
							set_cell(map, x, y, CELLS[current_tile_selection].state);
				push_history();
		if Input.is_action_just_pressed("paste_selection"):
			var tilepos = (map.get_local_mouse_position() / 16).floor();
			if tilepos.sign() == Vector2(1, 1) and tilepos.x < mapsize_x and tilepos.y < mapsize_y and current_step == 0:
				var errors = deserialize_map(OS.clipboard, tilepos);
				if errors != null and not errors.empty():
					log_for_user(make_deserialize_error_message(errors));
				push_history();
	
	for d in "0123456789ABCDEF":
		if Input.is_action_just_pressed(d) and not Input.is_key_pressed(KEY_CONTROL):
			var barrel_name = "barrel-" + d;
			if current_tile_selection == barrel_name:
				select_tile("crate-" + d);
			else:
				select_tile(barrel_name);
	
	if Input.is_action_just_pressed("?") and not Input.is_key_pressed(KEY_CONTROL):
		if current_tile_selection == "barrel-?":
			select_tile("crate-?");
		else:
			select_tile("barrel-?");
	
	if Input.is_action_just_pressed("select_next_tile"):
		select_tile_relative(Vector2(1, 0));
	
	if Input.is_action_just_pressed("select_previous_tile"):
		select_tile_relative(Vector2(-1, 0));
	
	if Input.is_action_just_pressed("select_below_tile"):
		select_tile_relative(Vector2(0, 1));
	
	if Input.is_action_just_pressed("select_above_tile"):
		select_tile_relative(Vector2(0, -1));


func _gui_input(event):
	var map = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap;
	var tilepos = (map.get_local_mouse_position() / 16).floor();
	
	var pallete_map = $PanelContainer2/TileMap;
	var pallete_pos = (pallete_map.get_local_mouse_position() / 16).floor();
	if event is InputEventMouseButton and pallete_pos.y >= 0 and pallete_pos.y < 3:
		var c = pallete_map.get_cellv(pallete_pos);
		var next = null;
		for name in CELLS.keys():
			if CELLS[name].state == c:
				assert (next == null); # Fail on duplicates in the pallete
				next = name;
		
		if next != null and not (banned_tiles != null and banned_tiles.has(CELLS[next].state)):
			select_tile(next);
	
	elif (
		$PanelContainer4/ScrollContainer.get_local_mouse_position().sign() == Vector2(1, 1) and
		tilepos.sign() == Vector2(1, 1) and tilepos.x < mapsize_x and tilepos.y < mapsize_y and current_step == 0
	):
		var mouse_bindings = {
			1: current_tile_selection, # left
			2: "empty", # right
		};
		if event is InputEventMouse and Input.is_key_pressed(KEY_SHIFT):
			paste_mode = null;
			if event is InputEventMouseButton and event.button_index == 2:
				select_none();
			if event is InputEventMouseButton and event.button_index == 1 and event.pressed:
				set_selection(tilepos, tilepos);
			if Input.is_mouse_button_pressed(1) and selection_end != null:
				set_selection(selection_start, tilepos);
		elif event is InputEventMouseButton and event.button_index in mouse_bindings:
			if event.pressed:
				last_held_mouse_button = event.button_index;
				var cellstate = CELLS[mouse_bindings[event.button_index]].state;
				last_placed_cell_state = cellstate;
				set_cellv(map, tilepos, cellstate);
				push_history();
			else:
				last_placed_cell_state = null;
		elif event is InputEventMouseButton and event.button_index == 3 and event.pressed:
			var state = initial_map[xy(tilepos.x, tilepos.y)];
			for k in CELLS.keys():
				if CELLS[k].state == state:
					select_tile(k);
		elif event is InputEventMouseMotion and last_placed_cell_state != null and Input.is_mouse_button_pressed(last_held_mouse_button):
			set_cellv(map, tilepos, last_placed_cell_state);
			swap_history();


func select_none():
	selection_start = null;
	selection_end = null;
	$PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap/SelectionBorder.visible = false;
	$PanelContainer3/VBoxContainer/SelectionInfoLine/SelectionLabel.text = "";
	$PanelContainer3/VBoxContainer/SelectionInfoLine/NotSelectedLabel.visible = true;
	$PanelContainer3/VBoxContainer/SelectionInfoLine/SomethingSelectedLabel.visible = false;


func set_selection(start: Vector2, end: Vector2):
	selection_start = start;
	selection_end = end;
	render_selection_border(selection_start.x, selection_start.y, selection_end.x, selection_end.y);
	$PanelContainer3/VBoxContainer/SelectionInfoLine/SelectionLabel.text = str(abs(selection_end.x - selection_start.x) + 1) + "×" + str(abs(selection_end.y - selection_start.y) + 1);
	$PanelContainer3/VBoxContainer/SelectionInfoLine/NotSelectedLabel.visible = false;
	$PanelContainer3/VBoxContainer/SelectionInfoLine/SomethingSelectedLabel.visible = true;


func get_selection_rect():
	var sel_min = Vector2(
			min(selection_start.x, selection_end.x), 
		max(min(selection_start.y, selection_end.y), 0)
	);
	var sel_max = Vector2(
			max(selection_start.x, selection_end.x) + 1, 
		min(max(selection_start.y, selection_end.y) + 1, mapsize_y)
	);
	return Rect2(sel_min, sel_max - sel_min);


func select_tile(next):
	var target = CELLS[next].state;
	if (banned_tiles != null and target in banned_tiles) or next == current_tile_selection:
		return;
	current_tile_selection = next;
	var pallete = $PanelContainer2/TileMap;
	var vec2s = pallete.get_used_cells_by_id(target);
	assert (vec2s.size() == 1);
	$PanelContainer2/TileMap/Sprite.offset = vec2s[0] * Vector2(16, 16);


func select_tile_relative(v: Vector2):
	var pallete = $PanelContainer2/TileMap;
	var vec2s = pallete.get_used_cells_by_id(CELLS[current_tile_selection].state);
	assert (vec2s.size() == 1);
	var sel_pos: Vector2 = vec2s[0];
	sel_pos += v;
	while pallete.get_cellv(sel_pos) == -1 or banned_tiles != null and pallete.get_cellv(sel_pos) in banned_tiles:
		if pallete.get_cellv(sel_pos) != -1:
			sel_pos += v;
		else:
			sel_pos -= v;
			assert (pallete.get_cellv(sel_pos) != -1);
			while pallete.get_cellv(sel_pos) != -1:
				sel_pos -= v;
			sel_pos += v; # Don't look at this funny or it'll infinite loop
	var state = pallete.get_cellv(sel_pos);
	for k in CELLS.keys():
		if CELLS[k].state == state:
			select_tile(k);


func set_map_scale(scale: Vector2):
	$PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap.scale = scale;
	$PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/UneditableTileMapOverlay.scale = scale;
	$PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer.rect_min_size = Vector2(mapsize_x, mapsize_y) * 16 * scale;


var logi = 0;
func log_for_user(text: String):
	logi += 1;
	var logc = $PanelContainer4/UserLogVBox;
	var logs = logc.get_children();
	var copylog = logs.back();
	var label = copylog.duplicate();
	logc.add_child_below_node(copylog, label);
	label.visible = true;
	label.bbcode_text = " [u]" + String(logi) + "[/u] [b]" + text + "[/b] ";
	print(text);
	var maxlogs = 6;
	if (logs.size() > maxlogs):
		logc.remove_child(logs[0]);
	
	var li = maxlogs - logs.size();
	for l in logs:
		(l as CanvasItem).modulate = Color8(255, 255, 255, li * li * (255 / maxlogs / maxlogs)); # poor man's alpha curve
		li += 1;
	
	last_log_update_time = Time.get_ticks_msec();


class CellData:
	var short: String = "";
	var state: int = -1;
	
	static func init(_short: String, _state: int) -> CellData:
		var n = CellData.new();
		n.short = _short;
		n.state = _state;
		return n;


const sorter_i: int = 4;
const adder_i: int = 5; const subtractor_i: int = 6;
const furnace_i: int = 7;
const dozerr_i: int = 8; const dozerl_i: int = 9;
const rampr_i: int = 12; const rampl_i: int = 13;
const beltr_i: int = 10; const beltl_i: int = 11;
const copieru_i: int = 16; const copierd_i: int = 17;
const pipeu_i: int = 14; const piped_i: int = 15;
const turnsignal_i: int = 21;
const winchu_i: int = 18; const winchd_i: int = 19;
const target_i: int = 1; const targetgood_i: int = 2; const targetbad_i: int = 3;
const gate_i: int = 22;
const gatel_i: int = 23; const gater_i: int = 24; const gateu_i: int = 25; const gated_i: int = 26;
const unbuildable_i: int = 27;
const tileforbidder_i: int = 63;
const barrel0_i: int = 28; const barrelquestion_i: int = 44;
const crate0_i: int = 46; const cratequestion_i: int = 62;
const vine_i: int = 67;
const fire_i: int = 68;
const planter_i: int = 69;

const burners = [furnace_i, fire_i];

var CELLS = {
	"empty": CellData.init(" ", 0),
	"dozer-r": CellData.init("(", dozerr_i),
	"dozer-l": CellData.init(")", dozerl_i),
	"furnace": CellData.init("F", furnace_i),
	"vine": CellData.init("♣", vine_i),
	"fire": CellData.init("♧", fire_i),
	"planter": CellData.init("P", planter_i),
	"wall": CellData.init("=", 20),
	"wall-ramp-r": CellData.init("◤", 66),
	"wall-ramp-l": CellData.init("◥", 65),
	"ramp-r": CellData.init("/", rampr_i),
	"ramp-l": CellData.init("\\", rampl_i),
	"belt-r": CellData.init(">", beltr_i),
	"belt-l": CellData.init("<", beltl_i),
	"copier-u": CellData.init("i", copieru_i),
	"copier-d": CellData.init("!", copierd_i),
	"pipe-u": CellData.init("A", pipeu_i),
	"pipe-d": CellData.init("V", piped_i),
	"turnsignal": CellData.init("T", turnsignal_i),
	"winch-u": CellData.init("M", winchu_i),
	"winch-d": CellData.init("W", winchd_i),
	"sorter": CellData.init("O", sorter_i),
	"adder": CellData.init("+", adder_i),
	"subtractor": CellData.init("-", subtractor_i),
	"target": CellData.init("t", target_i),
	"target-good": CellData.init("g", targetgood_i),
	"target-bad": CellData.init("b", targetbad_i),
	"gate": CellData.init("G", gate_i),
	"gate-l": CellData.init("←", gatel_i),
	"gate-r": CellData.init("→", gater_i),
	"gate-u": CellData.init("↑", gateu_i),
	"gate-d": CellData.init("↓", gated_i),
	"unbuildable": CellData.init("x", unbuildable_i),
	"tile-forbidder": CellData.init("X", tileforbidder_i),
	"barrel-0": CellData.init("0", barrel0_i),
	"barrel-1": CellData.init("1", 29),
	"barrel-2": CellData.init("2", 30),
	"barrel-3": CellData.init("3", 31),
	"barrel-4": CellData.init("4", 32),
	"barrel-5": CellData.init("5", 33),
	"barrel-6": CellData.init("6", 34),
	"barrel-7": CellData.init("7", 35),
	"barrel-8": CellData.init("8", 36),
	"barrel-9": CellData.init("9", 37),
	"barrel-A": CellData.init("a", 38),
	"barrel-B": CellData.init("b", 39),
	"barrel-C": CellData.init("c", 40),
	"barrel-D": CellData.init("d", 41),
	"barrel-E": CellData.init("e", 42),
	"barrel-F": CellData.init("f", 43),
	"barrel-?": CellData.init("?", barrelquestion_i),
	"crate-0": CellData.init("０", crate0_i),
	"crate-1": CellData.init("１", 47),
	"crate-2": CellData.init("２", 48),
	"crate-3": CellData.init("３", 49),
	"crate-4": CellData.init("４", 50),
	"crate-5": CellData.init("５", 51),
	"crate-6": CellData.init("６", 52),
	"crate-7": CellData.init("７", 53),
	"crate-8": CellData.init("８", 54),
	"crate-9": CellData.init("９", 55),
	"crate-A": CellData.init("Ａ", 56),
	"crate-B": CellData.init("Ｂ", 57),
	"crate-C": CellData.init("Ｃ", 58),
	"crate-D": CellData.init("Ｄ", 59),
	"crate-E": CellData.init("Ｅ", 60),
	"crate-F": CellData.init("Ｆ", 61),
	"crate-?": CellData.init("¿", cratequestion_i),
};

# Tiles that aren't cells are only used in overlays.
const overlay_i = 45;
const forbidoverlay_i = 64;

func is_barrel(id: int) -> bool:
	return id >= barrel0_i and id <= cratequestion_i;

const crate_barrel_offset = crate0_i - barrel0_i;
func barrel_value(id: int) -> int:
	return mod(id - barrel0_i, crate_barrel_offset);

func next_tick_rand_hex() -> int:
	if tick_seed_position >= tick_seed.length():
		tick_seed += (tick_seed + str(current_step)).md5_text();
	tick_seed_position += 1;
	return ("0x" + char(tick_seed.ord_at(tick_seed_position - 1))).hex_to_int();

func add_barrels(a: int, b: int) -> int:
	var a0 = barrel_value(a);
	var b0 = barrel_value(b);
	var result = mod(a0 + b0, 16);
	if a0 > 15 or b0 > 15:
		result = next_tick_rand_hex() % 16;
	if a >= crate0_i and b >= crate0_i:
		return result + crate0_i;
	return result + barrel0_i;

func sub_barrels(a: int, b: int) -> int:
	var a0 = barrel_value(a);
	var b0 = barrel_value(b);
	var result = mod(a0 - b0, 16);
	if a0 > 15 or b0 > 15:
		result = next_tick_rand_hex() % 16;
	if a >= crate0_i and b >= crate0_i:
		return result + crate0_i;
	return result + barrel0_i;


func set_cell(map: TileMap, x: int, y: int, cell: int):
	assert(current_step == 0);
	var p = xy(x, y);
	if level_map and level_map[p] != 0 or banned_tiles != null and banned_tiles.has(cell):
		return;
	map.set_cell(x, y, cell);
	initial_map[p] = cell;

func set_cellv(map: TileMap, pos: Vector2, cell: int):
	return set_cell(map, int(pos.x), int(pos.y), cell);


func render_selection_border(x: int, y: int, x2: int, y2: int):
	var border = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap/SelectionBorder;
	var oo = Vector2(.5, .5);
	border.clear_points();
	border.add_point(oo + 16 * Vector2(min(x, x2),     min(y, y2)    ));
	border.add_point(oo + 16 * Vector2(max(x, x2) + 1, min(y, y2)    ));
	border.add_point(oo + 16 * Vector2(max(x, x2) + 1, max(y, y2) + 1));
	border.add_point(oo + 16 * Vector2(min(x, x2),     max(y, y2) + 1));
	border.add_point(oo + 16 * Vector2(min(x, x2),     min(y, y2)    ));
	border.visible = true;


func _on_SandboxConfirmationDialog_confirmed():
	level_map = initial_map;
	Global.playing_campaign_level_with_path = null;
	Global.playing_campaign_solution_with_path = null;
	$PanelContainer3/VBoxContainer/SandboxCheckBox.pressed = true;


func _on_SandboxCheckBox_toggled(button_pressed):
	print_debug("_on_SandboxCheckBox_toggled" + str(button_pressed));
	var overlay = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/UneditableTileMapOverlay;
	var forbid_overlay = $PanelContainer2/ForbiddenTilesOverlay;
	if button_pressed:
		if level_map != initial_map or Global.playing_campaign_level_with_path != null:
			print_debug("Un-set-up sandbox mode engagement");
			$PanelContainer3/VBoxContainer/SandboxConfirmationDialog.popup_centered();
			$PanelContainer3/VBoxContainer/SandboxCheckBox.pressed = false;
		else:
			log_for_user("Entered Sandbox Mode");
			$PanelContainer3/VBoxContainer/CampaignLevelLabel.text = "";
			$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow/CampaignLevelLabel2.text = "";
			$PanelContainer4/ScrollContainer/VBoxContainer/CampaignTitleRow.visible = false;
			Global.playing_campaign_level_with_path = null;
			Global.playing_campaign_solution_with_path = null;
			level_map = null;
			banned_tiles = null;
			overlay.clear();
			forbid_overlay.clear();
	elif level_map == null:
		log_for_user("Entered Level Mode");
		overlay.clear();
		banned_tiles = [tileforbidder_i, unbuildable_i, target_i, targetgood_i, targetbad_i];
		level_map = PoolByteArray(range(mapsize_x * mapsize_y));
		for x in range(mapsize_x):
			for y in range(mapsize_y):
				var c = xy(x, y);
				level_map[c] = initial_map[c];
				if level_map[c] != 0:
					overlay.set_cell(x, y, overlay_i);
				if level_map[c] == tileforbidder_i:
					for tc in [
						xy(x - 1, y - 1), xy(x - 1, y), xy(x - 1, y + 1),
						xy(x    , y - 1),               xy(x    , y + 1),
						xy(x + 1, y - 1), xy(x + 1, y), xy(x + 1, y + 1),
					]:
						if tc >= 0 and tc < mapsize_x * mapsize_y and initial_map[tc] != 0 and not banned_tiles.has(initial_map[tc]):
							banned_tiles.append(initial_map[tc]);
							if initial_map[tc] == cratequestion_i:
								for d in "0123456789ABCDEF":
									banned_tiles.append(CELLS["crate-" + d].state);
							elif initial_map[tc] == barrelquestion_i:
								for d in "0123456789ABCDEF":
									banned_tiles.append(CELLS["barrel-" + d].state);
							elif initial_map[tc] == gate_i:
								banned_tiles.append_array([gated_i, gateu_i, gatel_i, gater_i]);
		
		var pallete = $PanelContainer2/TileMap;
		for pos in pallete.get_used_cells():
			var c = pallete.get_cellv(pos);
			if banned_tiles.has(c):
				forbid_overlay.set_cellv(pos, forbidoverlay_i);


func do_step():
	if tick_map_requested:
		return;
	if current_map == null:
		current_map = initial_map;
	tick_map_requested = true;
	if tick_map_trigger.post() != OK:
		print("Failed to trigger tick_map");
	render_selection_border(-1000, -1000, -1000, -1000);
	current_step += 1;
	$PanelContainer3/VBoxContainer/ResetButton.disabled = false;
	$PanelContainer3/VBoxContainer/SeedLineEdit.editable = false;
	$PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/UneditableTileMapOverlay.visible = false;
	$PanelContainer3/VBoxContainer/TimeInfoLine/TimeLabel.text = str(current_step);


func _on_Step_pressed():
	$PanelContainer3/VBoxContainer/PlayCheckBox.pressed = false;
	do_step();


func _on_ResetButton_pressed():
	var map = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap;
	if $PanelContainer3/VBoxContainer/PlayCheckBox.pressed:
		if tick_map_finish.wait() != OK:
			print("Failed to listen for tick_map completion");
		finish_tick();
	if current_map != null:
		for y in range(mapsize_y):
			for x in range(mapsize_x):
				var ind = xy(x, y);
				if current_map[ind] != initial_map[ind]:
					map.set_cell(x, y, initial_map[ind]);
		current_map = null;
		current_step = 0;
		$PanelContainer3/VBoxContainer/ResetButton.disabled = true;
		$PanelContainer3/VBoxContainer/SeedLineEdit.editable = true;
		$PanelContainer3/VBoxContainer/PlayCheckBox.pressed = false;
		$PanelContainer3/VBoxContainer/SolvedInfoLine.visible = false;
		$PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/UneditableTileMapOverlay.visible = true;
		$PanelContainer3/VBoxContainer/TimeInfoLine/TimeLabel.text = str(current_step);
		set_editing_buttons_disabled();
	
	if selection_end != null:
		render_selection_border(selection_start.x, selection_start.y, selection_end.x, selection_end.y);


func serialize_map(mapdata: PoolByteArray, rect: Rect2 = Rect2(0, 0, mapsize_x, mapsize_y)) -> String:
	var lookup = {};
	for ck in CELLS.keys():
		lookup[CELLS[ck].state] = CELLS[ck].short;
	
	var result = "";
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			result += lookup[mapdata[xy(x, y)]];
		result += "\n";
	return result;


func deserialize_map(src: String, offset: Vector2 = Vector2.ZERO) -> Array: # returns list of errors
	var lookup = {};
	for ck in CELLS.keys():
		lookup[CELLS[ck].short] = CELLS[ck].state;
	
	var failures = [];
	var lines = src.split("\n");
	var map = $PanelContainer4/ScrollContainer/VBoxContainer/ViewportContainer/TileMap;
	for y in range(lines.size()):
		var line: String = lines[y].trim_suffix("\r");
		for x in range(line.length()):
			var c = line[x];
			var p = Vector2(x, y) + offset;
			if p.x < mapsize_x and p.y < mapsize_y:
				if c in lookup:
					set_cell(map, p.x, p.y, lookup[c]);
				else:
					set_cell(map, p.x, p.y, 0);
					if not c in failures:
						failures.append("Unknown character " + c);
	return failures;


func serialize_level() -> String:
	var level = level_map;
	if level == null:
		level = initial_map;
	return JSON.print({
		"solution": serialize_map(initial_map),
		"level": serialize_map(level),
		"requirements": level_requirements,
	}, "  ", true);


func deserialize_level(src: String) -> Array: # returns list of errors
	var res: JSONParseResult = JSON.parse(src);
	if res.error != OK:
		return [res.error_string];
	if not res.result.has("solution"):
		return ["Expected key \"solution\""];
	if not res.result.has("level"):
		return ["Expected key \"level\""];
	var reqs = res.result.get("requirements", [["", 10, 0]]);
	level_requirements = [];
	var levelreqs = $PanelContainer4/ScrollContainer/VBoxContainer/LevelRequirements;
	var req_template = $PanelContainer4/ScrollContainer/VBoxContainer/LevelRequirements/LevelRequirementProgressBar
	for req_node in levelreqs.get_children():
		if req_node != req_template:
			levelreqs.remove_child(req_node);
	for req in reqs:
		if not (req[0] is String and (req[1] is int or req[1] is float)):
			return ["Bad level requirement " + JSON.print(req)];
		level_requirements.append([req[0], int(req[1]), 0]);
		var req_node = req_template.duplicate();
		levelreqs.add_child(req_node);
		req_node.value = 0;
		req_node.connect("gui_input", self, "level_requirement_gui_input", [req[0]]);
		if req[0] == "":
			req_node.get_child(0).text = "Solve for " + str(int(req[1])) + " ticks:";
		else:
			req_node.get_child(0).text = "Solve seed \"" + req[0] + "\" for " + str(int(req[1])) + " ticks:"; 
		req_node.visible = true;
	var errs = deserialize_map(res.result["level"]);
	if not errs.empty():
		return errs;
	assert($PanelContainer3/VBoxContainer/SandboxCheckBox.pressed);
	$PanelContainer3/VBoxContainer/SandboxCheckBox.pressed = false;
	_on_SandboxCheckBox_toggled(false);
	return deserialize_map(res.result["solution"]);


func make_deserialize_error_message(failures: Array) -> String:
	return JSON.print({"Errors": failures});


func level_requirement_gui_input(event, testseed: String):
	if event is InputEventMouseButton and event.pressed and event.button_index == 1:
		var seedfield = $PanelContainer3/VBoxContainer/SeedLineEdit;
		if seedfield.editable:
			seedfield.text = testseed;


func set_LoadFileDialog_path():
	var dialog = $PanelContainer3/VBoxContainer/LoadFileDialog;
	if Global.playing_campaign_level_with_path == null:
		dialog.access = FileDialog.ACCESS_RESOURCES;
		dialog.filters = ["*.rlvl ; Saved Levels"];
		if !dialog.current_dir.begins_with("res://"):
			dialog.current_dir = "res://";
	elif Global.playing_campaign_solution_with_path == null:
		dialog.access = FileDialog.ACCESS_USERDATA;
		var prefix = Global.get_campaign_level_prefix();
		dialog.filters = [prefix + "*.rlvl ; Saved solutions to " + prefix];
		dialog.current_path = "user://CampaignSaves/" + prefix;
	else:
		dialog.access = FileDialog.ACCESS_USERDATA;
		var prefix = Global.get_campaign_level_prefix();
		dialog.filters = [prefix + "*.rlvl ; Saved solutions to " + prefix];
		dialog.current_path = Global.playing_campaign_solution_with_path;
	dialog.invalidate();


func _on_SaveButton_pressed():
	set_LoadFileDialog_path();
	$PanelContainer3/VBoxContainer/LoadFileDialog.mode = FileDialog.MODE_SAVE_FILE;
	$PanelContainer3/VBoxContainer/LoadFileDialog.popup_centered_clamped(Vector2(800, 600));


func _on_LoadButton_pressed():
	set_LoadFileDialog_path();
	$PanelContainer3/VBoxContainer/LoadFileDialog.mode = FileDialog.MODE_OPEN_FILE;
	$PanelContainer3/VBoxContainer/LoadFileDialog.popup_centered_clamped(Vector2(800, 600));


func _on_LoadFileDialog_file_selected(path: String):
	var dialog = $PanelContainer3/VBoxContainer/LoadFileDialog;
	if dialog.mode == FileDialog.MODE_OPEN_FILE:
		if current_step != 0:
			log_for_user("Cannot load when not reset.");
		elif load_map(path):
			log_for_user("Failed to load " + path);
		else:
			log_for_user("Loaded " + path);
			push_history();
	else:
		assert(dialog.mode == FileDialog.MODE_SAVE_FILE);
		if Global.playing_campaign_level_with_path != null and path.get_base_dir() != "user://CampaignSaves":
			log_for_user("Level Select won't detect solutions in subfolders");
		var levelprefix = Global.get_campaign_level_prefix();
		if "*" in path: # AAAAHHHHH I think godot does this wrong and this fixes it
			var prefix = levelprefix + "*.rlvl";
			path = path.left(path.length() - prefix.length() + 1);
			if not path.ends_with(".rlvl"):
				path += ".rlvl";
		if not path.get_file().begins_with(levelprefix):
			path = path.get_base_dir() + "/" + levelprefix + path.get_file();
		save_map(path);


func _on_MarkCompletedButton_pressed():
	save_map("user://CampaignSaves/" + Global.get_campaign_level_prefix().trim_suffix("-") + ".rlvl");
	if get_tree().change_scene("res://levelselect.tscn") != OK:
		print("Failed to open level select");
	


func save_map(path: String):
	var file = File.new();
	if file.open(path, File.WRITE) != OK:
		log_for_user("Failed to save map " + path);
		return;
	if path.get_extension() == "rlvl":
		file.store_string(serialize_level());
		file.close();
		log_for_user("Saved level to " + path);
	else:
		log_for_user("Unknown extension :\"" + path.get_extension() + "\"");
	$PanelContainer3/VBoxContainer/LoadFileDialog.invalidate();
	$PanelContainer3/VBoxContainer/LoadFileDialog2.invalidate();


func load_map(path: String) -> bool:
	var file = File.new();
	if file.open(path, File.READ) != OK:
		return true;
	_on_ResetButton_pressed();
	initial_map.fill(0);
	if level_map != null:
		level_map = initial_map;
		$PanelContainer3/VBoxContainer/SandboxCheckBox.pressed = true;
	assert (level_map == null);
	assert ($PanelContainer3/VBoxContainer/SandboxCheckBox.pressed);
	
	var errors = null;
	if path.get_extension() == "rlvl":
		errors = deserialize_level(file.get_as_text());
	if errors != null and not errors.empty():
		log_for_user(make_deserialize_error_message(errors));
	
	map_history.clear();
	map_history_position = -1;
	return false;


func _on_ZoomCheckBox_toggled(button_pressed):
	if button_pressed:
		set_map_scale(Vector2(2, 2));
	else:
		set_map_scale(Vector2(1, 1));


func push_history():
	if map_history_position != map_history.size() - 1:
		map_history.resize(map_history_position + 1);
	map_history_position += 1;
	map_history.append(serialize_map(initial_map));
	set_editing_buttons_disabled();
	for i in range(level_requirements.size()):
		var req = level_requirements[i];
		if req[2] != 0:
			req[2] = 0;
			$PanelContainer4/ScrollContainer/VBoxContainer/LevelRequirements.get_child(i + 1).value = 0;


func swap_history():
	map_history[map_history_position] = serialize_map(initial_map);
	set_editing_buttons_disabled();


func set_editing_buttons_disabled():
	$PanelContainer3/VBoxContainer/UndoButton.disabled = map_history_position == 0 or current_step > 0;
	$PanelContainer3/VBoxContainer/RedoButton.disabled = map_history_position == map_history.size() - 1 or current_step > 0;
	$PanelContainer3/VBoxContainer/LoadButton.disabled = current_step > 0;
	$PanelContainer3/VBoxContainer/SaveButton.disabled = current_step > 0;


func _on_UndoButton_pressed():
	if map_history_position > 0 and current_step == 0:
		map_history_position -= 1;
		if not deserialize_map(map_history[map_history_position]).empty():
			print("Undo failed to deserialize");
	set_editing_buttons_disabled();


func _on_RedoButton_pressed():
	if map_history_position < map_history.size() - 1 and current_step == 0:
		map_history_position += 1;
		if not deserialize_map(map_history[map_history_position]).empty():
			print("Redo failed to deserialize");
	set_editing_buttons_disabled();


func tick_map_step_1():
	# The furnace and target and ? and gate step
	for y in range(mapsize_y):
		for x in range(mapsize_x):
			var here: int = xy(x, y);
			var above: int = here - mapsize_x; # xy(x, y - 1);
			var above2: int = above - mapsize_x; # xy(x, y - 2);
			var below: int = here + mapsize_x; # xy(x, y + 1);
			var below2: int = below + mapsize_x; # xy(x, y + 2);
			var l1: int = xy(x - 1, y);
			var l2: int = xy(x - 2, y);
			var r1: int = xy(x + 1, y);
			var r2: int = xy(x + 2, y);
			var nmhere: int = current_map[here];
			var nmr1: int = current_map[r1];
			var nml1: int = current_map[l1];
			var nmr2: int = current_map[r2];
			var nml2: int = current_map[l2];
			if nmhere == unbuildable_i or is_barrel(nmhere) and (
				nmr1 in burners or
				nml1 in burners or
				y != mapsize_y - 1 and current_map[below] in burners or
				y != 0             and current_map[above] in burners
			):
				nmhere = 0;
				current_changed[here] = 1;
			if nmhere == vine_i and (
				nmr1 in burners and current_changed[r1] == 0 or
				nml1 in burners and current_changed[l1] == 0 or
				y != mapsize_y - 1 and current_map[below] in burners and current_changed[below] == 0 or
				y != 0             and current_map[above] in burners and current_changed[above] == 0
			):
				nmhere = fire_i;
				current_changed[here] = 1;
			
			if y > 1 and current_map[above] in [target_i, targetbad_i, targetgood_i]:
				current_map[above] = target_i;
				var nma2 = current_map[above2];
				if is_barrel(nma2) and nma2 >= crate0_i and is_barrel(nmhere) and nmhere >= crate0_i:
					if nma2 == nmhere:
						current_map[above] = targetgood_i;
					else:
						current_map[above] = targetbad_i;
			
			# Resolve ? barrels
			if is_barrel(nmhere) and barrel_value(nmhere) == 16 and not (y > 0 and current_map[above] == copieru_i) and not (y < mapsize_y - 1 and current_map[below] == copierd_i):
				nmhere = add_barrels(crate0_i, nmhere); # TODO simplify
			# Gate
			if nmhere == gated_i and (y > 1 or not current_map[above] == gate_i or current_map[above2] in [0, gateu_i]):
				nmhere = 0;
			if nmhere == gateu_i and (y < mapsize_y - 2 or not current_map[below] == gate_i or current_map[below2] in [0, gated_i]):
				nmhere = 0;
			if nmhere == gatel_i and (not nmr1 == gate_i or current_map[r2] in [0, gater_i]):
				nmhere = 0;
			if nmhere == gater_i and (not nml1 == gate_i or current_map[l2] in [0, gatel_i]):
				nmhere = 0;
			
			if nmhere == 0:
				if y > 1 and current_map[above] == gate_i and not current_map[above2] in [0, gateu_i]:
					nmhere = gated_i;
				if y < mapsize_y - 2 and current_map[below] == gate_i and not current_map[below2] in [0, gated_i]:
					nmhere = gateu_i;
				if nmr1 == gate_i and not nmr2 in [0, gater_i]:
					nmhere = gatel_i;
				if nml1 == gate_i and not nml2 in [0, gatel_i]:
					nmhere = gater_i;
			
			current_map[here] = nmhere;


func tick_map_step_2_a(y: int):
	var y1 = y - 1;
	for x in range(mapsize_x):
		var here: int = xy(x, y);
		var above: int = here - mapsize_x; # xy(x, y1);
		var a_above: int = above - mapsize_x; # xy(x, y - 2);
		var l1: int = xy(x - 1, y);
		var l2: int = xy(x - 2, y);
		var l_above: int = l1 - mapsize_x; # xy(x - 1, y1);
		var r1: int = xy(x + 1, y);
		var r_above: int = r1 - mapsize_x; # xy(x + 1, y1);
		
		if current_map[here] == fire_i and current_changed[here] == 0:
			current_map[here] = 0;
			current_changed[here] = 1;
		
		if y1 >= 0:
			var nma = current_map[above];
			
			if nma == 0 and current_changed[above] == 0 and (current_map[here] == planter_i or current_map[here] == vine_i and current_changed[here] == 0):
				nma = vine_i;
				current_map[above] = vine_i;
				current_changed[above] = 1;
			
			if current_map[here] == 0:
				# Fall
				if current_changed[above] == 0 and (
					nma == dozerl_i or nma == dozerr_i or is_barrel(nma)
				):
					current_map[here] = nma;
					current_map[above] = 0;
					nma = 0;
					current_changed[here] = 1;
				
				# Fall down ramps
				elif nma == 0 and current_map[l1] == rampl_i and current_changed[l_above] == 0 and (current_map[l_above] == dozerr_i or is_barrel(current_map[l_above])):
					current_map[here] = current_map[l_above];
					current_map[l_above] = 0;
					current_changed[here] = 1;
				elif nma == 0 and current_map[r1] == rampr_i and current_changed[r_above] == 0 and (current_map[r_above] == dozerl_i or is_barrel(current_map[r_above])):
					current_map[here] = current_map[r_above];
					current_map[r_above] = 0;
					current_changed[here] = 1;
				
				# Math
				elif is_barrel(current_map[l1]) and current_changed[l1] == 0 and is_barrel(current_map[l2]) and current_changed[l2] == 0:
					var operator = current_map[l_above];
					if operator == adder_i:
						current_map[here] = add_barrels(current_map[l2], current_map[l1]);
						current_map[l1] = 0;
						current_map[l2] = 0;
						current_changed[here] = 1;
					elif operator == subtractor_i:
						current_map[here] = sub_barrels(current_map[l2], current_map[l1]);
						current_map[l1] = 0;
						current_map[l2] = 0;
						current_changed[here] = 1;
			
			var y2: int = y - 2;
			if y2 >= 0:
				if (nma == copieru_i or nma == winchu_i) and current_changed[here] == 0 and is_barrel(current_map[here]) and current_map[a_above] == 0:
					current_map[a_above] = current_map[here];
					current_changed[a_above] = 1;
					if nma == winchu_i:
						current_map[above] = winchd_i;
						nma = winchd_i;
						current_map[here] = 0;
					
				elif (nma == copierd_i or nma == winchd_i) and current_changed[a_above] == 0 and is_barrel(current_map[a_above]) and current_map[here] == 0:
					current_map[here] = current_map[a_above];
					current_changed[here] = 1;
					if nma == winchd_i:
						current_map[above] = winchu_i;
						current_map[above] = winchu_i;
						nma = winchu_i;
						current_map[a_above] = 0;
			
				# Pipe
				elif nma == pipeu_i and current_changed[here] == 0 and is_barrel(current_map[here]):
					var pipe_top: int = xy(x, y2);
					while pipe_top >= 0 and current_map[pipe_top] == pipeu_i:
						pipe_top -= mapsize_x;
					if pipe_top >= 0 and current_map[pipe_top] == 0:
						current_map[pipe_top] = current_map[here];
						current_changed[pipe_top] = 1;
						current_map[here] = 0;
				elif nma == piped_i and current_map[here] == 0:
					var pipe_top: int = xy(x, y2);
					while pipe_top >= 0 and current_map[pipe_top] == piped_i:
						pipe_top -= mapsize_x;
					if pipe_top >= 0 and is_barrel(current_map[pipe_top]):
						current_map[here] = current_map[pipe_top];
						current_changed[here] = 1;
						current_map[pipe_top] = 0;


func tick_map_step_2_b(y: int):
	# Push right
	for xx in range(mapsize_x):
		var x: int = mapsize_x - 1 - xx;
		var here = xy(x, y);
		if current_map[here] == fire_i and current_changed[here] == 0:
			current_map[here] = 0;
		
		if current_map[here] != 0:
			continue;
		var belt_c = 0;
		var path = [here];
		
		while path.size() == 1 or is_barrel(current_map[path.back()]):
			var over = addxy(path.back(), -1, 0);
			if iy(path.back()) == mapsize_y - 1:
				path.append(over);
				continue;
			
			var under = path.back() + mapsize_x;
			var uunder = under + mapsize_x;
			if current_changed[path.back()] == 0 and (
				current_map[under] == beltr_i or 
				uunder < mapsize_x * mapsize_y and current_map[under] == sorter_i and is_barrel(current_map[uunder]) and barrel_value(current_map[path.back()]) > barrel_value(current_map[uunder])
			):
				belt_c = path.size();
			if current_map[under] == rampr_i and current_map[over] == 0:
				path.append(addxy(path.back(), -1, 1));
			else:
				path.append(over);
		
		var back = path.back();
		if (
			current_map[back] == dozerr_i and
			current_changed[back] == 0 and
			not (iy(back) > 0 and current_map[addxy(back, 1, -1)] == turnsignal_i)
		):
			belt_c = path.size();
		if belt_c > 1:
			for i in range(belt_c - 1):
				var c = path[i];
				current_map[c] = current_map[path[i + 1]];
				current_changed[c] = 1;
			current_map[path[belt_c - 1]] = 0;
	
	# Push left
	for x in range(mapsize_x):
		var here: int = xy(x, y);
		if current_map[here] != 0:
			continue;
		var belt_c = 0;
		var path = [here];
		
		while path.size() == 1 or is_barrel(current_map[path.back()]):
			var over = addxy(path.back(), 1, 0);
			if iy(path.back()) == mapsize_y - 1:
				path.append(over);
				continue;
			
			var under = path.back() + mapsize_x;
			var uunder = under + mapsize_x;
			if current_changed[path.back()] == 0 and (
				current_map[under] == beltl_i or
				uunder < mapsize_x * mapsize_y and current_map[under] == sorter_i and is_barrel(current_map[uunder]) and barrel_value(current_map[path.back()]) <= barrel_value(current_map[uunder])
			):
				belt_c = path.size();
			if current_map[under] == rampl_i and current_map[over] == 0:
				path.append(addxy(path.back(), 1, 1));
			else:
				path.append(over);
		
		var back = path.back();
		if (
			current_map[back] == dozerl_i and
			current_changed[back] == 0 and
			not (iy(back) > 0 and current_map[addxy(back, -1, -1)] == turnsignal_i)
		):
			belt_c = path.size();
		if belt_c > 1:
			for i in range(belt_c - 1):
				var c = path[i];
				current_map[c] = current_map[path[i + 1]];
				current_changed[c] = 1;
			current_map[path[belt_c - 1]] = 0;


func tick_map_step_2_c(y: int):
	if y > 0:
		for x in range(mapsize_x):
			# Turn dozers
			if current_map[xy(x, y - 1)] == turnsignal_i:
				var l = xy(x - 1, y);
				if current_map[l] == dozerr_i and current_changed[l] == 0:
					current_map[l] = dozerl_i;
					current_changed[l] = 1;
				var r = xy(x + 1, y);
				if current_map[r] == dozerl_i and current_changed[r] == 0:
					current_map[r] = dozerr_i;
					current_changed[r] = 1;

func tick_map():
	current_changed.fill(0);
	
	var s = $PanelContainer3/VBoxContainer/SeedLineEdit.text;
	if s == "":
		for _i in range(10):
			s += "0123456789ABCDEF"[randi() % 16];
	tick_seed = s;
	tick_seed_position = 0;
	
	tick_map_step_1();
	for yy in range(mapsize_y):
		var y = mapsize_y - 1 - yy;
		tick_map_step_2_a(y);
		tick_map_step_2_b(y);
		tick_map_step_2_c(y);


func tick_map_thread_fn():
	while not tick_map_thread_fn_dead:
		if tick_map_trigger.wait() != OK:
			print("Failed to listen for tick_map triggers");
			return;
		if not tick_map_thread_fn_dead:
			tick_map();
			if tick_map_finish.post() != OK:
				print("Failed to signal end of tick_map");
				return;


func _on_OpenMenuButton_pressed():
	if get_tree().change_scene("res://TitleScene.tscn") != OK:
		print("Failed to open title");


func _on_OpenLevelsButton_pressed():
	if get_tree().change_scene("res://levelselect.tscn") != OK:
		print("Failed to open level select");


func _on_SeedLineEdit_text_changed(new_text: String):
	var re = RegEx.new();
	re.compile("[^A-Fa-f0-9]");
	var matches = re.search_all(new_text);
	for i in range(matches.size() - 1, -1, -1):
		var m: RegExMatch = matches[i];
		$PanelContainer3/VBoxContainer/SeedLineEdit.delete_text(m.get_start(), m.get_end());
