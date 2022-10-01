extends Node


var cheat_code_unlock_all_levels = false;

var playing_campaign_level_with_path = null;
var playing_campaign_solution_with_path = null;

func get_campaign_level_prefix() -> String:
	var levelname_parts = playing_campaign_level_with_path.get_file().get_basename().split("-");
	assert (levelname_parts.size() > 2);
	return levelname_parts[0] + "-" + levelname_parts[1] + "-";
