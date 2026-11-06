#!/bin/bash
# Claude Code Stop hook for a voice session: speaks the final reply of a turn that started from the voice app
# (a <channel source="herdr-voice"> message). Typed turns are not spoken, and neither is a turn where the session
# already called the speak tool itself. Sends to the voice app's socket. DRY_RUN=1 prints instead of sending.
# The reply comes from the hook input (last_assistant_message): the transcript file can lag behind the turn, so it is
# only used to see where the turn started.
sock="${HERDR_VOICE_SOCK:-$HOME/.config/herdr-voice/app.sock}"
in=$(cat)
tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty'); [ -f "$tp" ] || exit 0
reply=$(printf '%s' "$in" | jq -r '.last_assistant_message // empty')
origin=$(tail -n 400 "$tp" | jq -s -r '
  def txt: if (.message.content|type)=="string" then .message.content else ([.message.content[]? | select(.type=="text") | .text] | join(" ")) end;
  [ .[] | select(.type=="user" or .type=="assistant") ] as $m
  | ($m | to_entries | map(select(.value.type=="user" and ((.value|txt)|length>0))) | last) as $u
  | if $u == null or ((($u.value|txt)|test("<channel source=\"herdr-voice\"")) | not) then "other"
    elif ($m[($u.key+1):] | any(.type=="assistant" and ([.message.content[]? | select(.type=="tool_use") | .name] | any(test("speak"))))) then "spoke"
    else "voice" end')
[ "$origin" = voice ] || exit 0
[ -n "$reply" ] || exit 0
# Plain spoken text: no markdown, code, links or list markers, and no "What I skipped" sign-off. The whole reply is
# spoken, up to MAX_CHARS (cut at a sentence end).
text=$(printf '%s' "$reply" | python3 -c '
import re, sys
limit = int(sys.argv[1])
t = sys.stdin.read()
t = re.split(r"(?i)\n\s*what i skipped", t)[0]
t = re.sub(r"```.*?```", " ", t, flags=re.S)
t = re.sub(r"`[^`]*`", " ", t)
t = t.replace("**", "")
t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)
t = re.sub(r"(?m)^\s*(#+|>|[-*|])\s*", "", t)
t = re.sub(r"(^|\s)\d+[.)]\s+", " ", t)
t = re.sub(r"\s+", " ", t).strip()
if len(t) > limit:
    t = t[:limit]
    cut = max(t.rfind(". "), t.rfind("? "), t.rfind("! "))
    t = t[:cut + 1] if cut > limit // 2 else t.rsplit(" ", 1)[0]
print(t)
' "${MAX_CHARS:-1500}")
[ ${#text} -ge 2 ] || exit 0
if [ -n "$DRY_RUN" ]; then echo "WOULD SPEAK: $text"; exit 0; fi
jq -nc --arg t "$text" '{type:"speak",text:$t}' | nc -U -w 2 "$sock"
exit 0
