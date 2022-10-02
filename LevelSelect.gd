extends PanelContainer


func lsdir(path: String) -> PoolStringArray:
	var d = Directory.new();
	if d.open(path) != OK:
		print("Failed to open directory " + path);
		return PoolStringArray([]);
	var files = [];
	d.list_dir_begin(true);
	var file = d.get_next();
	while file != '':
		files += [file];
		file = d.get_next();
	return PoolStringArray(files);


func _ready():
	if !Directory.new().dir_exists("user://CampaignSaves"):
		if Directory.new().make_dir("user://CampaignSaves") != OK:
			print("Failed to create CampaignSaves directory");
	var savefiles = lsdir("user://CampaignSaves");
	
	var cols = $VBoxContainer/HBoxContainer;
	var sep_template = $VBoxContainer/HBoxContainer/VSeparator;
	var col_template = $VBoxContainer/HBoxContainer/VBoxContainer;
	var lvl_template = $VBoxContainer/HBoxContainer/VBoxContainer/VBoxContainer;
	col_template.visible = false;
	lvl_template.visible = false;
	
	var base = "res://Campaign";
	var files = lsdir(base);
	
	var completed_levels = {};
	
	for c in range(1, 100):
		var col_prefix = str(c) + "-";
		var colfiles = [];
		for fname in files:
			if fname.begins_with(col_prefix):
				colfiles.append(fname);
		if colfiles.empty():
			break;
		var colsaves = [];
		for fname in savefiles:
			if fname.begins_with(col_prefix):
				colsaves.append(fname);
		if c > 1:
			var sep = sep_template.duplicate();
			cols.add_child(sep);
			sep.visible = true;
			
		var lset = col_template.duplicate();
		cols.add_child(lset);
		lset.visible = true;
		for l in range(1, 100):
			var prefix = col_prefix + str(l) + "-";
			var matches = [];
			for fname in colfiles:
				if fname.begins_with(prefix):
					matches.append(fname);
			if matches.empty():
				break;
			assert (matches.size() == 1);
			var completed = false;
			var completionfname = col_prefix + str(l) + ".rlvl";
			for fname in colsaves:
				if fname == completionfname:
					completed = true;
			completed_levels[prefix] = completed;
			var saves = [];
			for fname in colsaves:
				if fname.begins_with(prefix):
					saves.append(fname);
			if completed:
				saves.append(completionfname);
			var fname: String = matches[0];
			var lvl = lvl_template.duplicate();
			lset.add_child(lvl);
			lvl.visible = true;
			var lvlbtn = lvl.get_child(1);
			if not completed:
				lvlbtn.icon = null;
			lvlbtn.hint_tooltip = fname;
			lvlbtn.text = str(c) + "·" + str(l);
			lvlbtn.disabled = not (completed or Global.cheat_code_unlock_all_levels or (l == 1 and c == 1));
			if l > 1 and completed_levels.get(col_prefix + str(l - 1) + "-", false):
				lvlbtn.disabled = false;
			if c > 1 and completed_levels.get(str(c - 1) + "-" + str(l) + "-", false):
				lvlbtn.disabled = false;
			var path = base + "/" + fname;
			if lvlbtn.connect("pressed", self, "_on_button_pressed", [lvl, path]) != OK:
				print("Failed to connect level button " + path);
			var levelnamelabel: Label = lvl.get_child(0).get_child(0);
			levelnamelabel.text = fname.get_basename().right(prefix.length()).split("-").join(" ");
			if lvlbtn.disabled:
				levelnamelabel.modulate = Color(1, 1, 1, 0.35);
			else:
				levelnamelabel.modulate = Color(1, 1, 1, 1);
			var solutionmenu: MenuButton = lvl.get_child(0).get_child(1);
			if saves.empty():
				solutionmenu.disabled = true;
			else:
				solutionmenu.disabled = false;
				for si in range(saves.size()):
					solutionmenu.get_popup().add_item(saves[si].trim_suffix(".rlvl"), si);
				var savepaths = []
				for s in saves:
					savepaths.append("user://CampaignSaves/" + s);
				if solutionmenu.get_popup().connect("id_pressed", self, "_on_solutionmenu_pressed", [path, savepaths]) != OK:
					print("Failed to connect solutionmenu button");


func _on_solutionmenu_pressed(id: int, levelpath: String, savepaths: Array):
	Global.playing_campaign_level_with_path = levelpath;
	Global.playing_campaign_solution_with_path = savepaths[id];
	if get_tree().change_scene("res://firstScene.tscn") != OK:
		print("Failed to open editor");


func _on_button_pressed(_lvl, path: String):
	Global.playing_campaign_level_with_path = path;
	Global.playing_campaign_solution_with_path = null;
	if get_tree().change_scene("res://firstScene.tscn") != OK:
		print("Failed to open editor");


func _on_OpenMenuButton_pressed():
	if get_tree().change_scene("res://TitleScene.tscn") != OK:
		print("Failed to open title");
