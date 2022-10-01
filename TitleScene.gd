extends PanelContainer

func _on_OpenEditorButton_pressed():
	Global.playing_campaign_level_with_path = null;
	Global.playing_campaign_solution_with_path = null;
	if get_tree().change_scene("res://firstScene.tscn") != OK:
		print("_on_OpenEditorButton_pressed error");


func _on_SelectLevelButton_pressed():
	if get_tree().change_scene("res://levelselect.tscn") != OK:
		print("_on_SelectLevelButton_pressed error");


func _on_DonateButton_pressed():
	if OS.shell_open("https://paypal.me/ColinYergin") != OK:
		print("_on_DonateButton_pressed error");


func _on_GodotLicenseButton_pressed():
	if OS.shell_open("https://godotengine.org/license") != OK:
		print("_on_GodotLicenseButton_pressed error");


func _on_rubiconLinkButton_pressed():
	if OS.shell_open("https://kevan.org/rubicon") != OK:
		print("_on_rubiconLinkButton_pressed error");


func _on_CheatButton_pressed():
	Global.cheat_code_unlock_all_levels = true;
	_on_SelectLevelButton_pressed();
