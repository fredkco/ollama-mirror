#!/usr/bin/env bash
set -uo pipefail

# ollama-fetch.sh
#
# Build a simple HTTP-served offline repository for Ollama models.
#
# Input list format:
#   llama3.2
#   llama3.2:latest
#   qwen2.5-coder:7b
#   myuser/mymodel:latest
#   # comments are ignored
#
# Output:
#   blobs/*
#   models/*.Modelfile
#   manifest.tsv
#   manifest.json
#   index.html
#   repo-metadata.env
#   ollama-offline.sh
#
# Usage:
#   chmod +x ollama-fetch.sh
#   ./ollama-fetch.sh models.list
#   ./ollama-fetch.sh models.list ./ollama-offline

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <model-list-file> [output-dir]"
  exit 1
fi

LIST_FILE="$(realpath "$1")"
OUT_DIR="$(realpath -m "${2:-./ollama-offline}")"

if [[ ! -f "$LIST_FILE" ]]; then
  echo "ERROR: list file not found: $LIST_FILE"
  exit 1
fi

mkdir -p "$OUT_DIR"

STATE_DIR="$OUT_DIR/.state"
BLOBS_DIR="$OUT_DIR/blobs"
MODELFILES_DIR="$OUT_DIR/models"
META_DIR="$OUT_DIR/.metadata"

mkdir -p "$STATE_DIR" "$BLOBS_DIR" "$MODELFILES_DIR" "$META_DIR"

DOWNLOADED_DB="$STATE_DIR/downloaded.txt"
FAILED_DB="$STATE_DIR/failed.txt"
LOG_FILE="$STATE_DIR/run.log"
REQUESTED_DB="$STATE_DIR/requested.txt"

touch "$DOWNLOADED_DB" "$FAILED_DB" "$LOG_FILE" "$REQUESTED_DB"
# Keep requested models scoped to the current execution so stale failures can be pruned.
: > "$REQUESTED_DB"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

require_cmd ollama
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd sort
require_cmd tee
require_cmd date
require_cmd basename
require_cmd realpath
require_cmd stat

log() {
  local msg="$1"
  echo "$msg" | tee -a "$LOG_FILE"
}

normalize_line() {
  local line="$1"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"
  printf '%s\n' "$line"
}

ensure_tag() {
  local ref="$1"
  local tail="${ref##*/}"

  if [[ "$tail" == *:* ]]; then
    printf '%s\n' "$ref"
  else
    printf '%s:latest\n' "$ref"
  fi
}

safe_ref_name() {
  local ref="$1"
  printf '%s\n' "$ref" | sed 's#[/:]#_#g'
}

db_has_line() {
  local value="$1"
  local file="$2"
  grep -Fxsq "$value" "$file"
}

db_add_line() {
  local value="$1"
  local file="$2"
  if [[ -n "$value" ]] && ! db_has_line "$value" "$file"; then
    printf '%s\n' "$value" >> "$file"
  fi
}

clear_failed_for_ref() {
  local model_ref="$1"
  local tmp

  [[ -z "$model_ref" ]] && return 0
  [[ -f "$FAILED_DB" ]] || return 0

  tmp="$(mktemp)"
  grep -Fvx "$model_ref" "$FAILED_DB" > "$tmp" || true
  mv -f "$tmp" "$FAILED_DB"
}

mark_requested() {
  local model_ref="$1"
  db_add_line "$model_ref" "$REQUESTED_DB"
}

mark_downloaded() {
  local model_ref="$1"
  db_add_line "$model_ref" "$DOWNLOADED_DB"
}

mark_failed() {
  local model_ref="$1"
  db_add_line "$model_ref" "$FAILED_DB"
}

metadata_file_for_ref() {
  local model_ref="$1"
  local safe
  safe="$(safe_ref_name "$model_ref")"
  printf '%s/%s.tsv\n' "$META_DIR" "$safe"
}

parse_metadata_file() {
  local metadata_file="$1"
  local field_index="$2"
  awk -F'\t' -v i="$field_index" 'NR==1 {print $i; exit}' "$metadata_file"
}

blob_list_exists() {
  local blob_csv="$1"
  local blob_rel

  if [[ -z "$blob_csv" || "$blob_csv" == "-" ]]; then
    return 1
  fi

  IFS=',' read -r -a blob_arr <<< "$blob_csv"
  for blob_rel in "${blob_arr[@]}"; do
    [[ -z "$blob_rel" ]] && continue
    if [[ ! -f "$OUT_DIR/$blob_rel" ]]; then
      return 1
    fi
  done

  return 0
}

metadata_record_is_valid() {
  local metadata_file="$1"
  local modelfile_rel
  local blob_csv

  if [[ ! -f "$metadata_file" ]]; then
    return 1
  fi

  modelfile_rel="$(parse_metadata_file "$metadata_file" 4)"
  blob_csv="$(parse_metadata_file "$metadata_file" 5)"

  [[ -z "$modelfile_rel" || "$modelfile_rel" == "-" ]] && return 1
  [[ ! -f "$OUT_DIR/$modelfile_rel" ]] && return 1

  blob_list_exists "$blob_csv" || return 1
  return 0
}

write_metadata_record() {
  local metadata_file="$1"
  local model_input="$2"
  local model_ref="$3"
  local safe_name="$4"
  local modelfile_rel="$5"
  local blob_csv="$6"
  local blob_count="$7"
  local total_bytes="$8"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$model_input" \
    "$model_ref" \
    "$safe_name" \
    "$modelfile_rel" \
    "$blob_csv" \
    "$blob_count" \
    "$total_bytes" > "$metadata_file"
}

pull_model() {
  local model_ref="$1"
  local rc=0
  local tmp_pull_log

  log "==> Pulling model: [$model_ref]"
  tmp_pull_log="$(mktemp)"
  ollama pull "$model_ref" 2>&1 | tee -a "$LOG_FILE" "$tmp_pull_log"
  rc=${PIPESTATUS[0]}

  if [[ "$rc" -ne 0 ]] && grep -Fqi "file does not exist" "$tmp_pull_log"; then
    log "HINT: model not found: $model_ref (check spelling/tag, e.g. deepseek-r1:latest)"
  fi
  rm -f "$tmp_pull_log"

  log "==> pull rc=$rc for $model_ref"
  return "$rc"
}

show_modelfile() {
  local model_ref="$1"
  ollama show --modelfile "$model_ref" 2>>"$LOG_FILE"
}

extract_blob_paths_from_modelfile() {
  local modelfile_content="$1"
  printf '%s\n' "$modelfile_content" \
    | awk '/^(FROM|ADAPTER)[[:space:]]+\// {print $2}' \
    | sort -u
}

copy_blob_into_repo() {
  local src="$1"
  local base
  local dst

  if [[ ! -f "$src" ]]; then
    return 1
  fi

  base="$(basename "$src")"
  dst="$BLOBS_DIR/$base"

  if [[ -f "$dst" ]]; then
    return 0
  fi

  cp -f "$src" "$dst"
}

rewrite_modelfile_to_placeholder_paths() {
  local modelfile_content="$1"
  local line
  local instruction
  local path
  local base

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^(FROM|ADAPTER)[[:space:]]+(/[^[:space:]]+)$ ]]; then
      instruction="${BASH_REMATCH[1]}"
      path="${BASH_REMATCH[2]}"
      base="$(basename "$path")"
      printf '%s __OLLAMA_BLOB_DIR__/%s\n' "$instruction" "$base"
      continue
    fi
    printf '%s\n' "$line"
  done <<< "$modelfile_content"
}

process_model() {
  local model_input="$1"
  local model_ref
  local safe_name
  local metadata_file
  local modelfile_content
  local modelfile_rel
  local modelfile_path
  local blob_srcs
  local blob_src
  local blob_base
  local blob_rel
  local blob_count=0
  local total_bytes=0
  local blob_csv="-"
  local blob_size=0
  local -a blob_rel_arr=()

  model_ref="$(ensure_tag "$model_input")"
  safe_name="$(safe_ref_name "$model_ref")"
  metadata_file="$(metadata_file_for_ref "$model_ref")"

  if metadata_record_is_valid "$metadata_file"; then
    log "Skipping already exported: $model_ref"
    mark_downloaded "$model_ref"
    clear_failed_for_ref "$model_ref"
    return 0
  fi

  if ! pull_model "$model_ref"; then
    log "WARN: pull failed: $model_ref"
    mark_failed "$model_ref"
    return 1
  fi

  modelfile_content="$(show_modelfile "$model_ref" || true)"
  if [[ -z "$modelfile_content" ]]; then
    log "WARN: could not read modelfile for $model_ref"
    mark_failed "$model_ref"
    return 1
  fi

  blob_srcs="$(extract_blob_paths_from_modelfile "$modelfile_content" || true)"
  if [[ -z "$blob_srcs" ]]; then
    log "WARN: no local blob paths found in modelfile for $model_ref"
    mark_failed "$model_ref"
    return 1
  fi

  while IFS= read -r blob_src; do
    [[ -z "$blob_src" ]] && continue

    if ! copy_blob_into_repo "$blob_src"; then
      log "WARN: blob copy failed for $model_ref: $blob_src"
      mark_failed "$model_ref"
      return 1
    fi

    blob_base="$(basename "$blob_src")"
    blob_rel="blobs/$blob_base"
    blob_rel_arr+=("$blob_rel")
    blob_count=$((blob_count + 1))

    blob_size="$(stat -c%s "$OUT_DIR/$blob_rel" 2>/dev/null || echo 0)"
    total_bytes=$((total_bytes + blob_size))
  done <<< "$blob_srcs"

  if [[ "${#blob_rel_arr[@]}" -gt 0 ]]; then
    blob_csv="$(IFS=','; echo "${blob_rel_arr[*]}")"
  fi

  modelfile_rel="models/${safe_name}.Modelfile"
  modelfile_path="$OUT_DIR/$modelfile_rel"

  rewrite_modelfile_to_placeholder_paths "$modelfile_content" > "$modelfile_path"

  write_metadata_record \
    "$metadata_file" \
    "$model_input" \
    "$model_ref" \
    "$safe_name" \
    "$modelfile_rel" \
    "$blob_csv" \
    "$blob_count" \
    "$total_bytes"

  mark_downloaded "$model_ref"
  clear_failed_for_ref "$model_ref"
  log "OK: exported $model_ref"
  return 0
}

seed_from_list() {
  local raw_line
  local line
  local model_ref

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(normalize_line "$raw_line")"
    [[ -z "$line" ]] && continue
    model_ref="$(ensure_tag "$line")"
    mark_requested "$model_ref"
    process_model "$line" || true
  done < "$LIST_FILE"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

generate_manifest_tsv() {
  local manifest="$OUT_DIR/manifest.tsv"
  local metadata_file
  local model_input
  local model_ref
  local safe_name
  local modelfile_rel
  local blob_csv
  local blob_count
  local total_bytes

  {
    printf 'model_input\tmodel_ref\tblob_count\ttotal_bytes\tmodelfile\tblob_files\n'

    find "$META_DIR" -maxdepth 1 -type f -name '*.tsv' | sort | while read -r metadata_file; do
      model_input="$(parse_metadata_file "$metadata_file" 1)"
      model_ref="$(parse_metadata_file "$metadata_file" 2)"
      safe_name="$(parse_metadata_file "$metadata_file" 3)"
      modelfile_rel="$(parse_metadata_file "$metadata_file" 4)"
      blob_csv="$(parse_metadata_file "$metadata_file" 5)"
      blob_count="$(parse_metadata_file "$metadata_file" 6)"
      total_bytes="$(parse_metadata_file "$metadata_file" 7)"

      [[ -z "$model_ref" ]] && continue
      [[ -z "$safe_name" ]] && continue
      [[ -z "$modelfile_rel" ]] && continue
      [[ ! -f "$OUT_DIR/$modelfile_rel" ]] && continue
      blob_list_exists "$blob_csv" || continue

      [[ -z "$blob_count" ]] && blob_count=0
      [[ -z "$total_bytes" ]] && total_bytes=0

      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$model_input" \
        "$model_ref" \
        "$blob_count" \
        "$total_bytes" \
        "$modelfile_rel" \
        "$blob_csv"
    done
  } > "$manifest"
}

generate_manifest_json() {
  local json="$OUT_DIR/manifest.json"
  local model_input
  local model_ref
  local blob_count
  local total_bytes
  local modelfile_rel
  local blob_csv
  local first=1

  {
    echo "["
    tail -n +2 "$OUT_DIR/manifest.tsv" | while IFS=$'\t' read -r model_input model_ref blob_count total_bytes modelfile_rel blob_csv; do
      [[ -z "$model_ref" ]] && continue

      if [[ "$first" -eq 0 ]]; then
        echo ","
      fi
      first=0

      printf '  {"model_input":"%s","model_ref":"%s","blob_count":%s,"total_bytes":%s,"modelfile":"%s","blob_files":"%s"}' \
        "$(json_escape "$model_input")" \
        "$(json_escape "$model_ref")" \
        "${blob_count:-0}" \
        "${total_bytes:-0}" \
        "$(json_escape "$modelfile_rel")" \
        "$(json_escape "$blob_csv")"
    done
    echo
    echo "]"
  } > "$json"
}

generate_repo_metadata_env() {
  local f="$OUT_DIR/repo-metadata.env"
  cat > "$f" <<EOF
REPO_GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
REPO_FORMAT_VERSION="1"
MANIFEST_FILE="manifest.tsv"
MANIFEST_JSON_FILE="manifest.json"
INDEX_FILE="index.html"
EOF
}

generate_ollama_offline_client() {
  local f="$OUT_DIR/ollama-offline.sh"

cat > "$f" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

OLLAMA_REPO_URL="${OLLAMA_REPO_URL:-http://your-server/ollama-offline}"
MANIFEST_URL="${OLLAMA_REPO_URL%/}/manifest.tsv"
SNAP_OLLAMA=0
SNAP_OLLAMA_MODELS_DIR="${SNAP_OLLAMA_MODELS_DIR:-}"
OLLAMA_CACHE_DIR="${OLLAMA_CACHE_DIR:-}"
MANIFEST_FILE=""
MODELFILES_DIR=""
BLOBS_DIR=""

detect_snap_ollama() {
  local ollama_bin

  SNAP_OLLAMA=0
  if ! ollama_bin="$(command -v ollama 2>/dev/null)"; then
    return 0
  fi

  # Avoid snap CLI probes here (they can trigger desktop policy prompts).
  # Infer snap packaging from the resolved ollama binary path.
  ollama_bin="$(readlink -f "$ollama_bin" 2>/dev/null || printf '%s' "$ollama_bin")"
  case "$ollama_bin" in
    /snap/*|/var/lib/snapd/snap/*|/usr/bin/snap)
      SNAP_OLLAMA=1
      ;;
    *)
      SNAP_OLLAMA=0
      ;;
  esac

  if [[ "$SNAP_OLLAMA" -eq 1 ]]; then
    SNAP_OLLAMA_MODELS_DIR="$(printf '%s' "$SNAP_OLLAMA_MODELS_DIR" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$SNAP_OLLAMA_MODELS_DIR" || "$SNAP_OLLAMA_MODELS_DIR" == "null" ]]; then
      SNAP_OLLAMA_MODELS_DIR="$HOME/snap/ollama/common/.ollama/models"
    fi
  fi
}

path_is_writable_or_creatable() {
  local path="$1"
  local parent

  [[ -n "$path" ]] || return 1

  if [[ -d "$path" ]]; then
    [[ -w "$path" ]]
    return
  fi

  parent="$(dirname "$path")"
  [[ -d "$parent" && -w "$parent" ]]
}

resolve_runtime_paths() {
  local needs_ollama_runtime="${1:-1}"
  local default_cache="$HOME/.cache/ollama-offline"

  if [[ "$needs_ollama_runtime" -eq 1 ]]; then
    detect_snap_ollama
    if [[ "$SNAP_OLLAMA" -eq 1 ]]; then
      default_cache="$HOME/snap/ollama/common/offline-cache"
      if [[ -n "$SNAP_OLLAMA_MODELS_DIR" ]] && ! path_is_writable_or_creatable "$SNAP_OLLAMA_MODELS_DIR"; then
        log "WARN: snap models dir is not writable: $SNAP_OLLAMA_MODELS_DIR"
        log "WARN: using ollama default models directory (no OLLAMA_MODELS override)"
        SNAP_OLLAMA_MODELS_DIR=""
      fi
    fi
  else
    SNAP_OLLAMA=0
    SNAP_OLLAMA_MODELS_DIR=""
  fi

  OLLAMA_CACHE_DIR="${OLLAMA_CACHE_DIR:-$default_cache}"
  MANIFEST_FILE="$OLLAMA_CACHE_DIR/manifest.tsv"
  MODELFILES_DIR="$OLLAMA_CACHE_DIR/models"
  BLOBS_DIR="$OLLAMA_CACHE_DIR/blobs"

  if path_is_writable_or_creatable "$OLLAMA_CACHE_DIR"; then
    mkdir -p "$OLLAMA_CACHE_DIR" "$MODELFILES_DIR" "$BLOBS_DIR"
  else
    echo "ERROR: cache directory is not writable: $OLLAMA_CACHE_DIR"
    echo "HINT: set OLLAMA_CACHE_DIR to a writable path (for example: $HOME/.cache/ollama-offline)"
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

log() {
  echo "[ollama-offline] $*"
}

download_url() {
  local url="$1"
  local out="$2"
  local tmp_out

  log "Downloading $url"
  tmp_out="${out}.tmp.$$"

  if ! wget -q -O "$tmp_out" "$url"; then
    rm -f "$tmp_out"
    echo "ERROR: download failed: $url"
    return 1
  fi

  if [[ ! -s "$tmp_out" ]]; then
    rm -f "$tmp_out"
    echo "ERROR: downloaded file is empty: $url"
    return 1
  fi

  mv -f "$tmp_out" "$out"
}

normalize_model_ref() {
  local ref="$1"
  local tail="${ref##*/}"
  if [[ "$tail" == *:* ]]; then
    printf '%s\n' "$ref"
  else
    printf '%s:latest\n' "$ref"
  fi
}

validate_manifest() {
  local expected_header
  expected_header=$'model_input\tmodel_ref\tblob_count\ttotal_bytes\tmodelfile\tblob_files'

  awk -F'\t' -v expected_header="$expected_header" '
    function fail(msg) {
      print "ERROR: " msg > "/dev/stderr"
      ok = 0
    }

    BEGIN {
      ok = 1
      rows = 0
    }

    NR == 1 {
      if ($0 != expected_header) {
        fail("manifest header mismatch")
      }
      next
    }

    {
      rows++
      if (NF < 6) {
        fail("manifest row " NR " has " NF " fields, expected 6")
        next
      }

      model_ref = $2
      blob_count = $3
      total_bytes = $4
      modelfile = $5
      blob_files = $6

      if (model_ref == "") {
        fail("manifest row " NR " has empty model_ref")
      }

      if (model_ref in seen) {
        fail("duplicate model_ref \"" model_ref "\" in rows " seen[model_ref] " and " NR)
      } else {
        seen[model_ref] = NR
      }

      if (blob_count !~ /^[0-9]+$/) {
        fail("invalid blob_count for " model_ref ": " blob_count)
      }

      if (total_bytes !~ /^[0-9]+$/) {
        fail("invalid total_bytes for " model_ref ": " total_bytes)
      }

      if (modelfile !~ /^models\//) {
        fail("invalid modelfile path for " model_ref ": " modelfile)
      }

      n = split(blob_files, arr, ",")
      for (i = 1; i <= n; i++) {
        if (arr[i] == "") {
          continue
        }
        if (arr[i] !~ /^blobs\//) {
          fail("invalid blob path for " model_ref ": " arr[i])
        }
      }
    }

    END {
      if (ok == 1) {
        print "[ollama-offline] Manifest OK (" rows " models)"
      }
      exit(ok ? 0 : 1)
    }
  ' "$MANIFEST_FILE"
}

download_manifest() {
  log "Downloading manifest..."
  download_url "$MANIFEST_URL" "$MANIFEST_FILE"

  if [[ ! -s "$MANIFEST_FILE" ]]; then
    echo "ERROR: manifest is missing or empty: $MANIFEST_FILE"
    exit 1
  fi

  log "Validating manifest consistency..."
  validate_manifest
}

get_row_by_ref() {
  local query="$1"
  local normalized
  normalized="$(normalize_model_ref "$query")"
  awk -F'\t' -v q="$query" -v n="$normalized" 'NR>1 && ($2==q || $2==n || $1==q || $1==n) {print; exit}' "$MANIFEST_FILE"
}

download_model_artifacts() {
  local model_ref="$1"
  local modelfile_rel="$2"
  local blob_csv="$3"
  local blob_rel

  download_url "${OLLAMA_REPO_URL%/}/$modelfile_rel" "$OLLAMA_CACHE_DIR/$modelfile_rel"

  IFS=',' read -r -a blob_arr <<< "$blob_csv"
  for blob_rel in "${blob_arr[@]}"; do
    [[ -z "$blob_rel" ]] && continue
    download_url "${OLLAMA_REPO_URL%/}/$blob_rel" "$OLLAMA_CACHE_DIR/$blob_rel"
  done
}

render_modelfile() {
  local src="$1"
  local dst="$2"
  local escaped_blob_dir

  escaped_blob_dir="$(printf '%s' "$BLOBS_DIR" | sed 's/[\/&]/\\&/g')"
  sed "s#__OLLAMA_BLOB_DIR__#$escaped_blob_dir#g" "$src" > "$dst"
}

ollama_create_from_modelfile() {
  local model_ref="$1"
  local modelfile="$2"

  if [[ "$SNAP_OLLAMA" -eq 1 && -n "$SNAP_OLLAMA_MODELS_DIR" ]]; then
    OLLAMA_MODELS="$SNAP_OLLAMA_MODELS_DIR" ollama create "$model_ref" -f "$modelfile"
    return
  fi

  ollama create "$model_ref" -f "$modelfile"
}

install_model() {
  local query="$1"
  local row
  local model_ref
  local modelfile_rel
  local blob_csv
  local rendered_modelfile

  row="$(get_row_by_ref "$query" || true)"
  if [[ -z "$row" ]]; then
    echo "ERROR: model not found in manifest: $query"
    return 1
  fi

  IFS=$'\t' read -r _ model_ref _ _ modelfile_rel blob_csv <<< "$row"

  log "Preparing $model_ref"
  download_model_artifacts "$model_ref" "$modelfile_rel" "$blob_csv"

  rendered_modelfile="$OLLAMA_CACHE_DIR/rendered-$(basename "$modelfile_rel")"
  render_modelfile "$OLLAMA_CACHE_DIR/$modelfile_rel" "$rendered_modelfile"

  log "Creating model $model_ref"
  ollama_create_from_modelfile "$model_ref" "$rendered_modelfile"
}

install_all() {
  local ref
  local had_failures=0

  while IFS=$'\t' read -r _ ref _ _ _ _; do
    [[ -z "$ref" ]] && continue
    if ! install_model "$ref"; then
      log "ERROR: failed to install $ref"
      had_failures=1
    fi
  done < <(tail -n +2 "$MANIFEST_FILE")

  return "$had_failures"
}

list_available() {
  echo "Available models from manifest:"
  awk -F'\t' '
    function human(bytes, units, i, value) {
      split("B KiB MiB GiB TiB PiB", units, " ")
      value = bytes + 0
      i = 1
      while (value >= 1024 && i < 6) {
        value /= 1024
        i++
      }
      if (i == 1) {
        return sprintf("%d %s", value, units[i])
      }
      return sprintf("%.1f %s", value, units[i])
    }

    BEGIN {
      n = 4
      headers[1] = "MODEL_REF"
      headers[2] = "BLOBS"
      headers[3] = "TOTAL_SIZE"
      headers[4] = "MODELFILE"
      for (i = 1; i <= n; i++) {
        w[i] = length(headers[i])
      }
    }
    NR > 1 {
      row++
      vals[row,1] = $2
      vals[row,2] = $3
      vals[row,3] = human($4)
      vals[row,4] = $5

      for (i = 1; i <= n; i++) {
        if (length(vals[row,i]) > w[i]) {
          w[i] = length(vals[row,i])
        }
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        fmt = (i == n) ? "%-" w[i] "s\n" : "%-" w[i] "s  "
        printf fmt, headers[i]
      }
      for (r = 1; r <= row; r++) {
        for (i = 1; i <= n; i++) {
          fmt = (i == n) ? "%-" w[i] "s\n" : "%-" w[i] "s  "
          printf fmt, vals[r,i]
        }
      }
    }
  ' "$MANIFEST_FILE"
}

usage() {
  echo "Usage: $0 install <model...> | install-all | list"
}

require_cmd wget
require_cmd awk
require_cmd sed
require_cmd grep

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift || true

NEEDS_OLLAMA_RUNTIME=0
case "$COMMAND" in
  install|install-all)
    NEEDS_OLLAMA_RUNTIME=1
    require_cmd ollama
    ;;
  list)
    NEEDS_OLLAMA_RUNTIME=0
    ;;
  *)
    usage
    exit 1
    ;;
esac

resolve_runtime_paths "$NEEDS_OLLAMA_RUNTIME"
if [[ "$NEEDS_OLLAMA_RUNTIME" -eq 1 && "$SNAP_OLLAMA" -eq 1 ]]; then
  log "Detected snap ollama; using cache dir: $OLLAMA_CACHE_DIR"
  if [[ -n "$SNAP_OLLAMA_MODELS_DIR" ]]; then
    log "Using snap models dir: $SNAP_OLLAMA_MODELS_DIR"
  else
    log "Using ollama default models directory (no override)"
  fi
fi

case "$COMMAND" in
  install)
    if [[ "$#" -lt 1 ]]; then
      echo "Usage: $0 install <model...>"
      exit 1
    fi
    download_manifest
    for m in "$@"; do
      install_model "$m"
    done
    ;;
  install-all)
    if [[ "$#" -gt 0 ]]; then
      echo "Usage: $0 install-all"
      exit 1
    fi
    download_manifest
    if ! install_all; then
      echo "ERROR: one or more models failed to install"
      exit 1
    fi
    ;;
  list)
    if [[ "$#" -gt 0 ]]; then
      echo "Usage: $0 list"
      exit 1
    fi
    download_manifest
    list_available
    ;;
  *)
    usage
    exit 1
    ;;
esac
EOF

  chmod +x "$f"
}

human_size() {
  local bytes="$1"
  awk -v b="$bytes" '
    function human(x) {
      split("B KiB MiB GiB TiB PiB", u, " ")
      i = 1
      while (x >= 1024 && i < 6) {
        x /= 1024
        i++
      }
      if (i == 1) {
        return sprintf("%d %s", x, u[i])
      }
      return sprintf("%.1f %s", x, u[i])
    }
    BEGIN { print human(b + 0) }'
}

generate_index_html() {
  local html="$OUT_DIR/index.html"
  local manifest="$OUT_DIR/manifest.tsv"
  local model_input
  local model_ref
  local blob_count
  local total_bytes
  local modelfile
  local blob_files
  local total_human

  {
    echo '<!DOCTYPE html>'
    echo '<html lang="en">'
    echo '<head>'
    echo '  <meta charset="utf-8">'
    echo '  <meta name="viewport" content="width=device-width, initial-scale=1">'
    echo '  <title>Offline Ollama Repository</title>'
    echo '  <style>'
    echo '    body { font-family: Arial, sans-serif; margin: 2rem; }'
    echo '    table { border-collapse: collapse; width: 100%; }'
    echo '    th, td { border: 1px solid #ccc; padding: 0.45rem; text-align: left; vertical-align: top; }'
    echo '    th { background: #f2f2f2; }'
    echo '    code, pre { background: #f7f7f7; padding: 0.2rem 0.4rem; }'
    echo '  </style>'
    echo '</head>'
    echo '<body>'
    echo '  <h1>Offline Ollama Repository</h1>'
    echo '  <p>This repository contains Ollama model artifacts for offline installation.</p>'
    echo '  <p>Generated by ollama-fetch.sh</p>'
    echo '  <p>'
    echo '    <a href="manifest.tsv">manifest.tsv</a> |'
    echo '    <a href="manifest.json">manifest.json</a> |'
    echo '    <a id="download-configured-client" href="ollama-offline.sh" download="ollama-offline.sh">ollama-offline.sh</a> |'
    echo '    <a href="repo-metadata.env">repo-metadata.env</a>'
    echo '  </p>'
    echo '  <table>'
    echo '    <thead>'
    echo '      <tr><th>Model</th><th>Blobs</th><th>Total size</th><th>Modelfile</th></tr>'
    echo '    </thead>'
    echo '    <tbody>'

    tail -n +2 "$manifest" | while IFS=$'\t' read -r model_input model_ref blob_count total_bytes modelfile blob_files; do
      total_human="$(human_size "${total_bytes:-0}")"
      printf '      <tr><td>%s</td><td>%s</td><td>%s</td><td><a href="%s">%s</a></td></tr>\n' \
        "$model_ref" "$blob_count" "$total_human" "$modelfile" "$modelfile"
    done

    echo '    </tbody>'
    echo '  </table>'
    echo '  <h2>Installation</h2>'
    echo '  <pre>'
    echo 'wget http://your-server/ollama-offline/ollama-offline.sh'
    echo 'chmod +x ollama-offline.sh'
    echo 'export OLLAMA_REPO_URL=http://your-server/ollama-offline'
    echo './ollama-offline.sh list'
    echo './ollama-offline.sh install llama3.2'
    echo './ollama-offline.sh install-all'
    echo '  </pre>'
    echo '  <p>Download <code>ollama-offline.sh</code> from the link at the top of this page.'
    echo '  The browser download is preconfigured for this repository URL.</p>'
    echo '  <p>If you use wget/curl directly, keep setting <code>OLLAMA_REPO_URL</code> manually.</p>'
    echo '  <script>'
    echo '    (function () {'
    echo '      var link = document.getElementById("download-configured-client");'
    echo '      if (!link || !window.fetch || !window.Blob || !window.URL) { return; }'
    echo '      link.addEventListener("click", async function (event) {'
    echo '        event.preventDefault();'
    echo '        var scriptUrl = new URL("ollama-offline.sh", window.location.href);'
    echo '        var repoUrl = new URL(".", scriptUrl).href.replace(/\/$/, "");'
    echo '        try {'
    echo '          var response = await fetch(scriptUrl.toString(), { cache: "no-store" });'
    echo '          if (!response.ok) { throw new Error("HTTP " + response.status); }'
    echo '          var content = await response.text();'
    echo '          var replacement = "OLLAMA_REPO_URL=\"${OLLAMA_REPO_URL:-" + repoUrl + "}\"";'
    echo '          content = content.replace("OLLAMA_REPO_URL=\"${OLLAMA_REPO_URL:-http://your-server/ollama-offline}\"", replacement);'
    echo '          var blob = new Blob([content], { type: "text/x-shellscript;charset=utf-8" });'
    echo '          var objectUrl = URL.createObjectURL(blob);'
    echo '          var downloader = document.createElement("a");'
    echo '          downloader.href = objectUrl;'
    echo '          downloader.download = "ollama-offline.sh";'
    echo '          document.body.appendChild(downloader);'
    echo '          downloader.click();'
    echo '          document.body.removeChild(downloader);'
    echo '          setTimeout(function () { URL.revokeObjectURL(objectUrl); }, 0);'
    echo '        } catch (err) {'
    echo '          console.error("Failed to build configured client:", err);'
    echo '          window.location.href = "ollama-offline.sh";'
    echo '        }'
    echo '      });'
    echo '    })();'
    echo '  </script>'
    echo '</body>'
    echo '</html>'
  } > "$html"
}

prune_failed_db() {
  local tmp
  local line
  local model_ref
  local metadata_file

  [[ -f "$FAILED_DB" ]] || return 0

  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    model_ref="$(ensure_tag "$line")"

    # Ignore failures from older runs that are not part of this request set.
    if ! db_has_line "$model_ref" "$REQUESTED_DB"; then
      continue
    fi

    metadata_file="$(metadata_file_for_ref "$model_ref")"
    if metadata_record_is_valid "$metadata_file"; then
      continue
    fi

    printf '%s\n' "$model_ref" >> "$tmp"
  done < "$FAILED_DB"

  mv -f "$tmp" "$FAILED_DB"
}

print_summary() {
  prune_failed_db

  echo
  echo "Done."
  echo

  if [[ -s "$DOWNLOADED_DB" ]]; then
    echo "Exported models:"
    sort -u "$DOWNLOADED_DB"
    echo
  fi

  if [[ -s "$FAILED_DB" ]]; then
    echo "Failed models:"
    sort -u "$FAILED_DB"
    echo
  fi

  echo "Output directory: $OUT_DIR"
  echo "Generated files:"
  echo "  $OUT_DIR/manifest.tsv"
  echo "  $OUT_DIR/manifest.json"
  echo "  $OUT_DIR/index.html"
  echo "  $OUT_DIR/ollama-offline.sh"
  echo "  $OUT_DIR/repo-metadata.env"
  echo "Log file:"
  echo "  $LOG_FILE"
}

log "Starting ollama-fetch"
log "List file: $LIST_FILE"
log "Output directory: $OUT_DIR"

seed_from_list

log "Generating manifest.tsv"
generate_manifest_tsv || log "WARN: manifest.tsv generation failed"

log "Generating manifest.json"
generate_manifest_json || log "WARN: manifest.json generation failed"

log "Generating repo-metadata.env"
generate_repo_metadata_env || log "WARN: repo metadata generation failed"

log "Generating ollama-offline.sh"
generate_ollama_offline_client || log "WARN: offline client generation failed"

log "Generating index.html"
generate_index_html || log "WARN: index.html generation failed"

print_summary
