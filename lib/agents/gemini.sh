#!/usr/bin/env bash

configure_gemini_mode_paths() {
	if [[ -d "$HOME/.gemini" ]]; then
		add_rw_path "$HOME/.gemini"
	fi
}

apply_gemini_arg_policies() {
	:
}
