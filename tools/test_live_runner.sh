#!/usr/bin/env bash
set -euo pipefail

fixture_main() {
  local provider="${SCRAPERS_LIVE_PROVIDER_FILTER:?missing provider filter}"
  local mode="${LIVE_RUNNER_FIXTURE_MODE:-pass}"
  local target="${LIVE_RUNNER_FIXTURE_TARGET:-}"
  local marker="$provider"

  case "$mode" in
    pass | fail | missing | fail-missing | duplicate | mixed | malformed | prompt | prompt-delay) ;;
    *)
      command echo "unknown live runner fixture mode: $mode" >&2
      exit 2
      ;;
  esac
  if [[ "$provider" != "$target" ]]; then
    command printf '[live][probe] provider=%s\n' "$provider"
    exit 0
  fi
  case "$mode" in
    missing | fail-missing) ;;
    duplicate)
      command printf '[live][probe] provider=%s\n' "$provider" "$provider"
      ;;
    mixed)
      command printf '[live][probe] provider=%s\n' "$provider" "${LIVE_RUNNER_FIXTURE_MARKER:?missing foreign marker}"
      ;;
    malformed)
      command printf 'noise-before-marker [live][probe] provider=%s\n' "$provider"
      ;;
    prompt | prompt-delay)
     if [[ -n "${LIVE_RUNNER_FIXTURE_MARKER:-}" ]]; then
       marker="$LIVE_RUNNER_FIXTURE_MARKER"
     fi
     command printf 'prompt-before-marker>'
      if [[ "$mode" == "prompt-delay" ]]; then
        command sleep 1
      fi
     command printf '\n[live][probe] provider=%s\n' "$marker"
      command printf 'prompt-after-marker'
      ;;
    *)
      if [[ -n "${LIVE_RUNNER_FIXTURE_MARKER:-}" ]]; then
        marker="$LIVE_RUNNER_FIXTURE_MARKER"
      fi
      command printf '[live][probe] provider=%s\n' "$marker"
      ;;
  esac
  if [[ "$mode" == "fail" || "$mode" == "fail-missing" ]]; then
    exit 17
  fi
  exit 0
}

if [[ "${0##*/}" == "fixture" ]]; then
  if [[ "${LIVE_RUNNER_CONTRACT_FIXTURE:-}" != "1" ]]; then
    command echo "live runner fixture invoked without its contract environment" >&2
    exit 2
  fi
  fixture_main
  exit 0
fi

if (( $# != 2 )); then
  command echo "usage: test_live_runner.sh SMOKE_SCRIPT_TEXT NAMED_SCRIPT_TEXT" >&2
  exit 2
fi

smoke_runner_script_text="$1"
named_runner_script_text="$2"
runner_script_text="$smoke_runner_script_text"
smoke_runner_script=""
named_runner_script=""
runner_script=""
sandbox=""
active_runner_pid=""
scenario_in_progress=0
completed_scenario_output=""
scenario_watchdog_seconds=20
contract_shutdown_poll_seconds=0.1
contract_shutdown_grace_ticks=70
env_bin=""
timeout_bin=""
bash_bin=""
grep_bin=""

contract_runner_is_live() {
  local wanted_pid="$1"
  local candidate_pid
  while IFS= read -r candidate_pid; do
    if [[ "$candidate_pid" == "$wanted_pid" ]]; then
      return 0
    fi
  done < <(jobs -pr; jobs -ps)
  return 1
}

terminate_active_runner() {
  local owned_pid="${active_runner_pid:-}"
  local attempt
  local -a candidates=()
  if [[ -z "$owned_pid" ]]; then
    # A trap may run after the background job is created but before $! is
    # assigned. During a scenario this harness owns exactly one direct job.
    if (( ! scenario_in_progress )); then
      return
    fi
    mapfile -t candidates < <(jobs -pr; jobs -ps)
    if (( ${#candidates[@]} != 1 )); then
      return
    fi
    owned_pid="${candidates[0]}"
  fi
  if contract_runner_is_live "$owned_pid"; then
    # This is fail-safe cleanup only. Normal contract scenarios wait for the
    # independently bounded runner and never signal it. SIGALRM enters GNU
    # timeout's own TERM/KILL watchdog path if fail-safe cleanup is needed.
    kill -ALRM "$owned_pid" 2>/dev/null || true
    kill -CONT "$owned_pid" 2>/dev/null || true
  fi
  for (( attempt = 0; attempt < contract_shutdown_grace_ticks; attempt++ )); do
    if ! contract_runner_is_live "$owned_pid"; then
      break
    fi
    command sleep "$contract_shutdown_poll_seconds"
  done
  if contract_runner_is_live "$owned_pid"; then
    kill -KILL "$owned_pid" 2>/dev/null || true
    active_runner_pid=""
    return
  fi
  # The job table says the child is terminal, so this only reaps cached status.
  wait "$owned_pid" 2>/dev/null || true
  active_runner_pid=""
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  terminate_active_runner
  if [[ -n "$sandbox" ]]; then
    command rm -rf -- "$sandbox"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for required_command in bash cat chmod cp env flock grep mkdir mkfifo mktemp rm sed sleep tee timeout; do
  if ! command type -P "$required_command" >/dev/null 2>&1; then
    command echo "live runner contract requires $required_command" >&2
    exit 2
  fi
done
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  command echo "live runner contract requires Bash 4.3 or newer" >&2
  exit 2
fi
env_bin="$(command type -P env)"
timeout_bin="$(command type -P timeout)"
bash_bin="$(command type -P bash)"
grep_bin="$(command type -P grep)"
if ! "$timeout_bin" --version 2>/dev/null | "$grep_bin" -F 'GNU coreutils' >/dev/null; then
  command echo "live runner contract requires GNU coreutils timeout" >&2
  exit 2
fi

command mkdir -p .tmp
sandbox="$(command mktemp -d .tmp/live-runner-contract.XXXXXX)"

work_dir="$sandbox/work"
fixture="$sandbox/fixture"
fixture_from_work="../fixture"
smoke_runner_script="$sandbox/live-runner-smoke.sh"
named_runner_script="$sandbox/live-runner-named.sh"
smoke_runner_from_work="../live-runner-smoke.sh"
named_runner_from_work="../live-runner-named.sh"
command mkdir -p "$work_dir"
command cp "$0" "$fixture"
command chmod 700 "$fixture"
command printf '%s' "$smoke_runner_script_text" > "$smoke_runner_script"
command printf '%s' "$named_runner_script_text" > "$named_runner_script"
# Production invokes the cached addWriteFiles output through Bash, so read
# permission is sufficient and the contract should not rely on an execute bit.
command chmod 600 "$smoke_runner_script" "$named_runner_script"
runner_script="$smoke_runner_from_work"

assert_line() {
  local file="$1"
  local text="$2"
  assert_line_count "$file" "$text" 1
}

assert_line_count() {
  local file="$1"
  local text="$2"
  local expected="$3"
  local count
  count="$(command grep -Fxc -- "$text" "$file" || true)"
  if (( count != expected )); then
    command echo "live runner contract count for '$text' was $count, expected $expected" >&2
    command sed -n '1,240p' "$file" >&2
    return 1
  fi
}

assert_text_count() {
  local file="$1"
  local text="$2"
  local expected="$3"
  local count
  count="$(command grep -Fc -- "$text" "$file" || true)"
  if (( count != expected )); then
    command echo "live runner contract text count for '$text' was $count, expected $expected" >&2
    command sed -n '1,240p' "$file" >&2
    return 1
  fi
}

assert_regex_count() {
  local file="$1"
  local regex="$2"
  local expected="$3"
  local count
  count="$(command grep -Ec -- "$regex" "$file" || true)"
  if (( count != expected )); then
    command echo "live runner contract regex count for '$regex' was $count, expected $expected" >&2
    command sed -n '1,240p' "$file" >&2
    return 1
  fi
}

assert_no_active_after_end() {
  local file="$1"
  local provider="$2"
  local line
  local active_names
  local active_name
  local -a active_items=()
  local ended=0
  while IFS= read -r line; do
    if [[ "$line" == "[live][runner] END $provider "* ]]; then
      ended=1
      continue
    fi
    if (( ended )) && [[ "$line" == "[live][runner] ACTIVE "* ]]; then
      active_names="${line#"[live][runner] ACTIVE "}"
      IFS=',' read -r -a active_items <<< "$active_names"
      for active_name in "${active_items[@]}"; do
        if [[ "$active_name" == "$provider" ]]; then
          command echo "live runner reported $provider active after its END record" >&2
          command sed -n '1,240p' "$file" >&2
          return 1
        fi
      done
    fi
  done < "$file"
}

assert_smoke_provider_cardinality() {
  local file="$1"
  local provider
  for provider in subdl.com opensubtitles.com sub-scene.com; do
    assert_text_count "$file" "[live][runner] START $provider" 1 || return 1
    assert_text_count "$file" "[live][runner] END $provider" 1 || return 1
    assert_no_active_after_end "$file" "$provider" || return 1
  done
}

assert_runner_tmp_removed() {
  if compgen -G "$work_dir/.tmp/live-runner.*" >/dev/null; then
    command echo "live runner left a temporary directory behind" >&2
    return 1
  fi
}

run_completed_scenario() {
  local label="$1"
  local mode="$2"
  local target="$3"
  local expected_rc="$4"
  local marker="${5:-}"
  local expected_started="${6:-3}"
  local output="$sandbox/$label.output"
  local rc
  command mkdir -p "$work_dir/.tmp"
  set +e
  scenario_in_progress=1
  (
    cd "$work_dir"
    exec "$env_bin" -u BASH_ENV -u ENV \
      LIVE_RUNNER_CONTRACT_FIXTURE=1 \
      LIVE_RUNNER_FIXTURE_MODE="$mode" \
      LIVE_RUNNER_FIXTURE_TARGET="$target" \
      LIVE_RUNNER_FIXTURE_MARKER="$marker" \
      SCRAPERS_LIVE_PROVIDER_FILTER=ambient.invalid \
      SCRAPERS_LIVE_PROVIDERS=ambient.invalid \
      "$timeout_bin" --signal=TERM --kill-after=5s "${scenario_watchdog_seconds}s" \
      "$bash_bin" "$runner_script" "$fixture_from_work"
  ) > "$output" 2>&1 &
  active_runner_pid=$!
  wait "$active_runner_pid"
  rc=$?
  active_runner_pid=""
  scenario_in_progress=0
  set -e
  if (( rc == 124 || rc == 137 )); then
    command echo "live runner scenario $label exceeded the independent ${scenario_watchdog_seconds}s watchdog" >&2
    command sed -n '1,240p' "$output" >&2
    return 1
  fi
  if (( rc != expected_rc )); then
    command echo "live runner scenario $label returned $rc, expected $expected_rc" >&2
    command sed -n '1,240p' "$output" >&2
    return 1
  fi
  assert_runner_tmp_removed || return 1
  assert_regex_count "$output" '^\[live\]\[runner\] START ' "$expected_started" || return 1
  assert_regex_count "$output" '^\[live\]\[runner\] END ' "$expected_started" || return 1
  assert_regex_count "$output" '^\[live\]\[runner\] SUMMARY ' 1 || return 1
  if (( expected_started == 3 )); then
    assert_smoke_provider_cardinality "$output" || return 1
  fi
  completed_scenario_output="$output"
}

assert_script_contains() {
  local text="$1"
  if [[ "$runner_script_text" != *"$text"* ]]; then
    command echo "live runner static contract missing: $text" >&2
    return 1
  fi
}

assert_script_not_contains() {
  local text="$1"
  if [[ "$runner_script_text" == *"$text"* ]]; then
    command echo "live runner static contract unexpectedly contains: $text" >&2
    return 1
  fi
}

assert_script_order() {
  local first="$1"
  local second="$2"
  if [[ "$runner_script_text" != *"$first"*"$second"* ]]; then
    command echo "live runner static contract order missing: $first before $second" >&2
    return 1
  fi
}

# Run scenarios in this shell rather than command substitutions: the top-level
# EXIT trap must always see active_runner_pid and own the bounded runner job.
run_completed_scenario success pass opensubtitles.com 0 opensubtitles_com
success_output="$completed_scenario_output"
assert_line "$success_output" "[live][runner] SUMMARY rc=0 mode=smoke selected=3 started=3 no_probe=0"

run_completed_scenario parallel-failure fail opensubtitles.com 1
failure_output="$completed_scenario_output"
assert_line "$failure_output" "[live][runner] END opensubtitles.com rc=17"
assert_line "$failure_output" "[live][runner] SUMMARY rc=1 mode=smoke selected=3 started=3 no_probe=0"

run_completed_scenario parallel-failure-missing fail-missing opensubtitles.com 1
failure_missing_output="$completed_scenario_output"
assert_line "$failure_missing_output" "[live][runner] MISSING_PROBE opensubtitles.com"
assert_line "$failure_missing_output" "[live][runner] END opensubtitles.com rc=17"

run_completed_scenario parallel-missing missing opensubtitles.com 1
missing_output="$completed_scenario_output"
assert_line "$missing_output" "[live][runner] MISSING_PROBE opensubtitles.com"
assert_line "$missing_output" "[live][runner] END opensubtitles.com rc=86"

run_completed_scenario repeated-valid-markers duplicate opensubtitles.com 0
duplicate_output="$completed_scenario_output"
assert_text_count "$duplicate_output" "[live][runner] DUPLICATE_PROBE" 0
assert_line "$duplicate_output" "[live][runner] END opensubtitles.com rc=0"

run_completed_scenario mixed-marker mixed opensubtitles.com 1 subdl.com
mixed_output="$completed_scenario_output"
assert_line "$mixed_output" "[live][runner] UNEXPECTED_PROBE opensubtitles.com"
assert_line "$mixed_output" "[live][runner] END opensubtitles.com rc=87"

run_completed_scenario wrong-marker pass opensubtitles.com 1 subdl.com
wrong_marker_output="$completed_scenario_output"
assert_line "$wrong_marker_output" "[live][runner] UNEXPECTED_PROBE opensubtitles.com"
assert_line "$wrong_marker_output" "[live][runner] MISSING_PROBE opensubtitles.com"
assert_line "$wrong_marker_output" "[live][runner] END opensubtitles.com rc=87"

run_completed_scenario trailing-marker pass opensubtitles.com 1 'opensubtitles.com trailing'
trailing_marker_output="$completed_scenario_output"
assert_line "$trailing_marker_output" "[live][runner] UNEXPECTED_PROBE opensubtitles.com"
assert_line "$trailing_marker_output" "[live][runner] MISSING_PROBE opensubtitles.com"
assert_line "$trailing_marker_output" "[live][runner] END opensubtitles.com rc=87"

run_completed_scenario malformed-marker malformed opensubtitles.com 1
malformed_marker_output="$completed_scenario_output"
assert_line "$malformed_marker_output" "[live][runner] UNEXPECTED_PROBE opensubtitles.com"
assert_line "$malformed_marker_output" "[live][runner] MISSING_PROBE opensubtitles.com"
assert_line "$malformed_marker_output" "[live][runner] END opensubtitles.com rc=87"

run_completed_scenario prompt-output prompt opensubtitles.com 0
prompt_output="$completed_scenario_output"
assert_line "$prompt_output" "[live][opensubtitles.com] prompt-before-marker>"
assert_line "$prompt_output" "[live][opensubtitles.com] [live][probe] provider=opensubtitles.com"
assert_line "$prompt_output" "[live][opensubtitles.com] prompt-after-marker"

run_completed_scenario prompt-overlap prompt-delay opensubtitles.com 0
prompt_overlap_output="$completed_scenario_output"
assert_line "$prompt_overlap_output" "[live][opensubtitles.com] prompt-before-marker>"
assert_line "$prompt_overlap_output" "[live][opensubtitles.com] [live][probe] provider=opensubtitles.com"
assert_line "$prompt_overlap_output" "[live][opensubtitles.com] prompt-after-marker"
assert_line_count "$prompt_overlap_output" "[live][opensubtitles.com] " 0
assert_line "$prompt_overlap_output" "[live][runner] END subdl.com rc=0"
assert_line "$prompt_overlap_output" "[live][runner] END opensubtitles.com rc=0"

run_completed_scenario serial-missing missing sub-scene.com 1
serial_missing_output="$completed_scenario_output"
assert_line "$serial_missing_output" "[live][runner] MISSING_PROBE sub-scene.com"
assert_line "$serial_missing_output" "[live][runner] END sub-scene.com rc=86 mode=serial"

runner_script="$named_runner_from_work"
runner_script_text="$named_runner_script_text"
run_completed_scenario named-no-probe pass subdl.com 0 '' 1
named_output="$completed_scenario_output"
assert_line "$named_output" "[live][runner] NO_PROBE isubtitles.org mode=named"
assert_line "$named_output" "[live][runner] SUMMARY rc=0 mode=named selected=2 started=1 no_probe=1"
assert_text_count "$named_output" "[live][runner] START isubtitles.org" 0
assert_text_count "$named_output" "[live][runner] END isubtitles.org" 0
runner_script="$smoke_runner_from_work"
runner_script_text="$smoke_runner_script_text"

assert_script_contains 'trap cleanup EXIT'
assert_script_contains "trap 'exit 130' INT"
assert_script_contains "trap 'exit 143' TERM"
assert_script_contains 'tmpdir=""'
assert_script_contains 'if [[ -n "$tmpdir" ]]'
assert_script_order 'trap '\''rc=$?;' 'tmpdir="$(command mktemp -d .tmp/live-runner.XXXXXX)"'
assert_script_contains 'terminate_all_runner_jobs'
assert_script_contains 'terminate_provider_pipeline'
assert_script_contains 'command rm -rf -- "$tmpdir"'
assert_script_contains 'timeout --signal=TERM --kill-after="$timeout_kill_after_seconds"s'
assert_script_contains 'command mkfifo "$output_fifo_path"'
assert_script_contains 'command cat "$output_fifo_path"'
assert_script_contains 'exec {output_keepalive_fd}<> "$output_fifo_path"'
assert_script_contains 'output_mux_terminal_path="$tmpdir/output-mux.terminal"'
assert_script_contains 'output_prefix="$2"'
assert_script_contains 'exec {output_fd}> "$output_fifo"'
assert_script_contains 'command printf "%s%s\n" "$output_prefix" "$chunk"'
assert_script_not_contains 'command printf "%s%s\n" "$2" "$chunk"'
assert_script_contains 'emit_record() {'
assert_script_contains 'command flock -x "$lock_fd"'
assert_script_contains 'IFS= read -r -t 0.25 -n 512 chunk'
assert_script_contains 'skip_empty_delimiter=1'
assert_script_contains 'for required_command in bash cat flock grep mkdir mkfifo mktemp rm sleep tee timeout; do'
assert_script_contains "command timeout --version 2>/dev/null | command grep -F 'GNU coreutils'"
assert_script_contains 'wait_for_provider_slot'
assert_script_contains 'wait_rcs[$i]=$?'
assert_script_contains 'if [[ "${reaped[$i]:-0}" == "1" ]]'
assert_script_not_contains 'wait -n'
assert_script_not_contains 'while IFS= read -r -n 1 byte; do'
assert_script_not_contains 'sed -u'
assert_script_contains 'validate_provider_probe'
assert_script_contains 'UNEXPECTED_PROBE'
assert_script_contains 'accepted_count == 0'
assert_script_not_contains 'DUPLICATE_PROBE'
assert_script_contains "command grep -F '[live][probe]'"
assert_script_contains 'terminate_one_runner_job ALRM "$provider_shutdown_grace_ticks"'
assert_script_order '> "$terminal_path"' 'command printf '\''%s\n'\'' "$record" >&"$output_stream_fd"'
assert_script_contains 'emit_terminal_record "[live][runner] END $name rc=$completion_rc" "$terminal_path"'
assert_script_contains '! -f "$tmpdir/$name.done" && ! -f "$tmpdir/$name.failed"'
assert_script_contains 'status cannot extend cleanup beyond the bounded poll above'

command echo "[live][runner-contract] SKIP signal execution; trap and cleanup structure checked statically"
command echo "LIVE_RUNNER_CONTRACT_PASS scenarios=13 signal_scenarios=static_only watchdog=bounded_normal_only"
