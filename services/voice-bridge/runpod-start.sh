#!/usr/bin/env bash
set -euo pipefail

workspace_dir="/workspace/eleven-voice-poc"
bridge_dir="${workspace_dir}/bridge-service"
source_repo="${VOICE_BRIDGE_SOURCE_REPO:-/workspace/m-secondbrain-source}"
source_ref="${VOICE_BRIDGE_GIT_REF:-df5ab372501e34f5e7211a9ab32f29f75eb23dbd}"
python_bin="${bridge_dir}/.venv/bin/python"
bridge_pid_file="${bridge_dir}/bridge.pid"
bridge_log_file="${bridge_dir}/bridge.log"
deployed_ref_file="${bridge_dir}/deployed-git-ref"
tunnel_pid_file="${bridge_dir}/cloudflared.pid"
tunnel_log_file="${bridge_dir}/cloudflared.log"
ssh_state_dir="${workspace_dir}/ssh"

fail() {
  echo "RunPod bootstrap failed: $*" >&2
  exit 1
}

pid_is_running() {
  local pid_file="$1"
  local expected_command="$2"
  [[ -f "${pid_file}" ]] || return 1
  local process_id
  process_id="$(<"${pid_file}")"
  [[ "${process_id}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${process_id}" 2>/dev/null || return 1
  [[ -r "/proc/${process_id}/cmdline" ]] || return 1
  tr '\0' ' ' <"/proc/${process_id}/cmdline" | grep -qF -- "${expected_command}"
}

adopt_single_process() {
  local pattern="$1"
  local pid_file="$2"
  local matches
  matches="$(pgrep -f "${pattern}" || true)"
  [[ -n "${matches}" ]] || return 1
  [[ "${matches}" != *$'\n'* ]] || fail "multiple existing processes match ${pattern}"
  printf '%s\n' "${matches}" >"${pid_file}"
}

install_ssh_identity() {
  command -v ssh-keygen >/dev/null || fail "ssh-keygen is unavailable"
  [[ -x /usr/sbin/sshd ]] || fail "/usr/sbin/sshd is unavailable"

  mkdir -p "${ssh_state_dir}/host_keys" /run/sshd /root/.ssh
  chmod 700 /root/.ssh

  if ! compgen -G "${ssh_state_dir}/host_keys/ssh_host_*_key" >/dev/null; then
    ssh-keygen -A
    cp /etc/ssh/ssh_host_*_key* "${ssh_state_dir}/host_keys/"
  else
    cp "${ssh_state_dir}"/host_keys/ssh_host_* /etc/ssh/
  fi

  if [[ -n "${RUNPOD_SSH_PUBLIC_KEY:-}" ]]; then
    case "${RUNPOD_SSH_PUBLIC_KEY}" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp*\ *) ;;
      *) fail "RUNPOD_SSH_PUBLIC_KEY is not a supported public key" ;;
    esac
    touch "${ssh_state_dir}/authorized_keys"
    grep -qxF "${RUNPOD_SSH_PUBLIC_KEY}" "${ssh_state_dir}/authorized_keys" ||
      printf '%s\n' "${RUNPOD_SSH_PUBLIC_KEY}" >>"${ssh_state_dir}/authorized_keys"
  fi

  [[ -s "${ssh_state_dir}/authorized_keys" ]] ||
    fail "set RUNPOD_SSH_PUBLIC_KEY before relying on SSH access"
  cp "${ssh_state_dir}/authorized_keys" /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys /etc/ssh/ssh_host_*_key

  /usr/sbin/sshd -t
  pgrep -x sshd >/dev/null || /usr/sbin/sshd
}

deploy_pinned_bridge() {
  [[ -d "${source_repo}/.git" ]] || fail "source repository is missing: ${source_repo}"
  git -C "${source_repo}" fetch --quiet origin
  git -C "${source_repo}" cat-file -e "${source_ref}^{commit}" 2>/dev/null ||
    fail "VOICE_BRIDGE_GIT_REF does not resolve to a commit"
  git -C "${source_repo}" checkout --quiet --detach "${source_ref}"
  mkdir -p "${bridge_dir}/bridge"
  cp -a "${source_repo}/services/voice-bridge/bridge/." "${bridge_dir}/bridge/"
}

start_bridge() {
  [[ -x "${python_bin}" ]] || fail "voice bridge virtual environment is missing"
  local deployed_ref=""
  [[ -f "${deployed_ref_file}" ]] && deployed_ref="$(<"${deployed_ref_file}")"
  if [[ "${deployed_ref}" != "${source_ref}" ]] &&
     pid_is_running "${bridge_pid_file}" "-m bridge.app"; then
    kill "$(<"${bridge_pid_file}")"
    sleep 1
  fi

  if ! pid_is_running "${bridge_pid_file}" "-m bridge.app"; then
    rm -f "${bridge_pid_file}"
    if ! adopt_single_process '[b]ridge.app' "${bridge_pid_file}"; then
      (
        cd "${bridge_dir}"
        nohup "${python_bin}" -m bridge.app >>"${bridge_log_file}" 2>&1 </dev/null &
        echo "$!" >"${bridge_pid_file}"
      )
    fi
  fi

  for _ in {1..20}; do
    if curl --fail --silent --show-error "http://127.0.0.1:${PORT:-8080}/health" >/dev/null; then
      printf '%s\n' "${source_ref}" >"${deployed_ref_file}"
      echo "Voice bridge is healthy at the pinned ref ${source_ref}."
      return
    fi
    sleep 1
  done
  tail -n 40 "${bridge_log_file}" >&2 || true
  fail "voice bridge health check timed out"
}

start_tunnel() {
  [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] || fail "CLOUDFLARE_TUNNEL_TOKEN is missing"
  local cloudflared_bin
  cloudflared_bin="$(command -v cloudflared || true)"
  [[ -n "${cloudflared_bin}" ]] || fail "cloudflared is unavailable"

  if ! pid_is_running "${tunnel_pid_file}" "cloudflared"; then
    rm -f "${tunnel_pid_file}"
    if ! adopt_single_process '[c]loudflared.*tunnel run' "${tunnel_pid_file}"; then
      nohup "${cloudflared_bin}" tunnel run --token "${CLOUDFLARE_TUNNEL_TOKEN}" \
        >>"${tunnel_log_file}" 2>&1 </dev/null &
      echo "$!" >"${tunnel_pid_file}"
    fi
  fi

  sleep 2
  pid_is_running "${tunnel_pid_file}" "cloudflared" ||
    fail "Cloudflare tunnel exited during startup"
}

install_ssh_identity
deploy_pinned_bridge
start_bridge
start_tunnel

if [[ -n "${PUBLIC_BASE_URL:-}" ]]; then
  public_health_url="${PUBLIC_BASE_URL%/}/health"
  if ! curl --fail --silent --show-error --retry 5 --retry-delay 1 \
    "${public_health_url}" >/dev/null; then
    fail "public bridge health check failed"
  fi
  echo "Public bridge health check passed."
fi

# Preserve Jupyter and any other services supplied by the RunPod base image.
exec /start.sh
