#!/usr/bin/env bash

configure_opencode_mode_paths() {
	local opencode_paths=(
		"$HOME/.opencode"
		"$HOME/.config/opencode"
		"$HOME/.cache/opencode"
		"$HOME/.local/share/opencode"
		"$HOME/.local/state/opencode"
	)

	local p
	for p in "${opencode_paths[@]}"; do
		if [[ -d "$p" ]]; then
			add_rw_path "$p"
		fi
	done
}

apply_opencode_arg_policies() {
	:
}
