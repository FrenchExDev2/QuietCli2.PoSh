#!/usr/bin/env bash
# Bash 4+, GNU timeout, Git, awk and jq. One JSON result; no raw native output.
set -uo pipefail
repo=${1:-.}
for dep in git awk jq timeout; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    printf '%s\n' '{"SchemaVersion":1,"Summary":"Missing Bash example dependency.","Outcome":"Unsupported","Data":null,"Execution":{"ExitCode":null,"AnalysisComplete":false},"Error":{"Code":"MissingDependency"},"Truncation":{"Applied":false,"Reasons":[]}}'
    exit 1
  fi
done
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

# The reducer is ordinary local code. Counters have constant memory.
# Git's v1 non-z format quotes control characters in filenames, so one status row
# corresponds to one entry. Only two counts are needed; paths are not returned.
timeout --signal=TERM --kill-after=2s 30s git -C "$repo" status --porcelain=v1 --untracked-files=normal \
  2> >(head -c 4096 > "$temp_dir/stderr-preview"; cat >/dev/null) |
  awk 'BEGIN { changed=0; untracked=0 }
       substr($0,1,2)=="??" { untracked++; next }
       { changed++ }
       END { printf "{\"Changed\":%d,\"Untracked\":%d}",changed,untracked }' > "$temp_dir/data.json"
codes=("${PIPESTATUS[@]}")
native_exit=${codes[0]}
parser_exit=${codes[1]}
outcome=Success
error=null
complete=true
if (( native_exit == 124 )); then
  outcome=Timeout; error='{"Code":"Timeout"}'; complete=false
elif (( native_exit != 0 || parser_exit != 0 )); then
  outcome=Failed; error='{"Code":"NativeOrParserFailed"}'; complete=false
fi
data=$(cat "$temp_dir/data.json")
if [[ $complete != true ]]; then data=null; fi

# No full log is read into the model. JSON is constructed by jq, never by
# interpolating filenames or untrusted native text into a JSON string.
json=$(jq -cn --arg outcome "$outcome" --argjson data "$data" \
  --argjson code "$native_exit" --argjson complete "$complete" --argjson error "$error" \
  '{SchemaVersion:1,Summary:"Git status reduced locally.",Outcome:$outcome,Data:$data,
    Execution:{ExitCode:$code,AnalysisComplete:$complete},Error:$error,
    Truncation:{Applied:false,Reasons:[]}}')
bytes=$(printf '%s' "$json" | wc -c)
if (( bytes > 2048 )); then
  json=$(printf '%s' "$json" | jq -c '.Data=null | .Truncation={Applied:true,Reasons:["OutputBudget"]}')
fi
printf '%s\n' "$json"
[[ $outcome == Success ]]
