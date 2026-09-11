#!/usr/bin/env bash
set -euo pipefail

bridge_dir="/workspace/eleven-voice-poc/bridge-service"
python_bin="${bridge_dir}/.venv/bin/python"
pid_file="${bridge_dir}/bridge.pid"
log_file="${bridge_dir}/bridge.log"

if [[ ! -x "${python_bin}" ]]; then
  echo "Voice bridge virtual environment is missing: ${python_bin}" >&2
  exit 1
fi

if [[ -f "${pid_file}" ]]; then
  existing_pid="$(<"${pid_file}")"
  if [[ "${existing_pid}" =~ ^[0-9]+$ ]] && kill -0 "${existing_pid}" 2>/dev/null; then
    echo "Voice bridge already running as PID ${existing_pid}."
  else
    rm -f "${pid_file}"
  fi
fi

if [[ ! -f "${pid_file}" ]]; then
  echo "Starting voice bridge on port ${PORT:-8080}."
  cd "${bridge_dir}"
  nohup "${python_bin}" -m bridge.app >>"${log_file}" 2>&1 &
  echo "$!" >"${pid_file}"
fi

exec /start.sh
