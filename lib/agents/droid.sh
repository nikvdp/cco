#!/usr/bin/env bash

configure_droid_mode_paths() {
	if [[ -d "$HOME/.factory" ]]; then
		add_rw_path "$HOME/.factory"
	fi
}

apply_droid_arg_policies() {
	:
}
