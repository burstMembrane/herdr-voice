#!/bin/bash
# Claude Code Stop hook for a voice session: speaks the final reply of a turn that started from the voice app
# (a <channel source="herdr-voice"> message). Typed turns are not spoken, and neither is a turn where the session
# already called the speak tool itself. Sends to the voice app's socket. DRY_RUN=1 prints instead of sending.
sock="${HERDR_VOICE_SOCK:-$HOME/.config/herdr-voice/app.sock}"
tp=$(jq -r '.transcript_path // empty'); [ -f "$tp" ] || exit 0
reply=$(tail -n 400 "$tp" | jq -s -r '
  def txt: if (.message.content|type)=="string" then .message.content else ([.message.content[]? | select(.type=="text") | .text] | join(" ")) end;
  [ .[] | select(.type=="user" or .type=="assistant") ] as $m
  | ($m | to_entries | map(select(.value.type=="user" and ((.value|txt)|length>0))) | last) as $u
  | if $u == null or ((($u.value|txt)|test("<channel source=\"herdr-voice\"")) | not) then ""
    else ($m[($u.key+1):]) as $after
      | if ($after | any(.type=="assistant" and ([.message.content[]? | select(.type=="tool_use") | .name] | any(test("speak"))))) then ""
        else ($after | map(select(.type=="assistant") | txt | select(length>0)) | last // "") end
    end')
[ -n "$reply" ] || exit 0
text=$(printf '%s' "$reply" | sed -E 's/```[^`]*```//g; s/`[^`]*`//g; s/\*\*//g; s/\[([^]]*)\]\([^)]*\)/\1/g; s/^[#>*| -]+//; s/\|//g' | tr '\n' ' ' | sed -E 's/  +/ /g')
text=$(printf '%s' "$text" | cut -c1-"${MAX_CHARS:-240}" | sed -E 's/([.!?]) [^.!?]*$/\1/')
[ ${#text} -ge 2 ] || exit 0
if [ -n "$DRY_RUN" ]; then echo "WOULD SPEAK: $text"; exit 0; fi
jq -nc --arg t "$text" '{type:"speak",text:$t}' | nc -U -w 2 "$sock"
exit 0
