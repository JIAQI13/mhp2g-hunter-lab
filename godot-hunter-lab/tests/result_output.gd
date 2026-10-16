extends RefCounted

static func path(original: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index: int = args.find("--results-path")
	if index >= 0:
		if index+1 >= args.size():
			push_error("--results-path requires a dedicated output directory")
			return ""
		var directory: String = args[index+1]
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) != OK:
			push_error("test output directory unavailable")
			return ""
		return directory.path_join(original.get_file())
	return original
