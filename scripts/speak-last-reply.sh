#!/bin/bash
# Claude Code Stop hook: speaks the start of the session's last reply in the Cloudflare voice (VoiceMode, speak only).
# Only when the turn was started by a person typing or dictating, not by a monitor event or another agent.
# DRY_RUN=1 prints what would be spoken. MAX_CHARS caps the spoken text (default 300).
in=$(cat)
tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty')
[ -f "$tp" ] || exit 0
last=$(tail -n 400 "$tp" | jq -s -r '
  def txt: if (.message.content|type)=="string" then .message.content else ([.message.content[]? | select(.type=="text") | .text] | join(" ")) end;
  [ .[] | select(.type=="user" or .type=="assistant") ] as $m
  | ($m | map(select(.type=="user") | txt | select(length>0)) | last // "") as $u
  | ($m | map(select(.type=="assistant") | txt | select(length>0)) | last // "") as $a
  | if ($u|test("^\\s*(<hc from=\"[^\"]+\">)?\\[Liam, speaking by voice\\]")) then $a elif ($u|test("^\\s*(<|Monitor event|\\[Image)")) then "" else $a end')
[ -n "$last" ] || exit 0
# plain spoken text: drop markdown, code, links and tables; keep the first sentences
text=$(printf '%s' "$last" | sed -E 's/```[^`]*```//g; s/`[^`]*`//g; s/\*\*//g; s/\[([^]]*)\]\([^)]*\)/\1/g; s/^[#>*| -]+//; s/\|//g' | tr '\n' ' ' | sed -E 's/  +/ /g')
max=${MAX_CHARS:-300}
text=$(printf '%s' "$text" | cut -c1-"$max" | sed -E 's/([.!?]) [^.!?]*$/\1/')
[ ${#text} -ge 12 ] || exit 0
if [ -n "$DRY_RUN" ]; then echo "WOULD SPEAK: $text"; exit 0; fi
nohup uvx --from voice-mode voicemode converse --skip-stt "$text" >/dev/null 2>&1 &
