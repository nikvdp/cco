#!/usr/bin/env bash

configure_omp_mode_paths() {
	local omp_paths=(
		"$HOME/${PI_CONFIG_DIR:-.omp}"
		"${PI_CODING_AGENT_DIR:-}"
		"${XDG_DATA_HOME:-$HOME/.local/share}/omp"
		"${XDG_STATE_HOME:-$HOME/.local/state}/omp"
		"${XDG_CACHE_HOME:-$HOME/.cache}/omp"
	)

	local p
	for p in "${omp_paths[@]}"; do
		if [[ -n "$p" && -d "$p" ]]; then
			add_rw_path "$p"
		fi
	done
}

apply_omp_arg_policies() {
	:
}
