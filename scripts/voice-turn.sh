#!/bin/bash
# Claude Code Stop hook for a hands-free voice loop in ONE pane: speak the start of the reply (about 150 characters) in the Cloudflare voice,
# then open Wispr Flow, listen (macOS speech detection ends the turn), and press Return so the pane gets your words.
# Runs only in the terminal named in ~/.config/herdr-voice/loop-terminal, and only while that pane is the focused one.
# Turn it off: delete that file. DRY_RUN=1 prints the plan instead of speaking/listening.
cfg="$HOME/.config/herdr-voice"
[ -f "$cfg/loop-terminal" ] || exit 0
[ "$HC_TERMINAL_ID" = "$(tr -d '[:space:]' < "$cfg/loop-terminal")" ] || exit 0

in=$(cat)
tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty')
[ -f "$tp" ] || exit 0
reply=$(tail -n 400 "$tp" | jq -s -r '
  def txt: if (.message.content|type)=="string" then .message.content else ([.message.content[]? | select(.type=="text") | .text] | join(" ")) end;
  [ .[] | select(.type=="user" or .type=="assistant") ] as $m
  | ($m | map(select(.type=="user") | txt | select(length>0)) | last // "") as $u
  | ($m | map(select(.type=="assistant") | txt | select(length>0)) | last // "") as $a
  | if ($u|test("^\\s*(<|Monitor event|\\[Image)")) then "" else $a end')
[ -n "$reply" ] || exit 0
text=$(printf '%s' "$reply" | sed -E 's/```[^`]*```//g; s/`[^`]*`//g; s/\*\*//g; s/\[([^]]*)\]\([^)]*\)/\1/g; s/^[#>*| -]+//; s/\|//g' | tr '\n' ' ' | sed -E 's/  +/ /g')
text=$(printf '%s' "$text" | cut -c1-"${MAX_CHARS:-150}" | sed -E 's/([.!?]) [^.!?]*$/\1/')
[ ${#text} -ge 12 ] || exit 0

# Only open the mic when this pane is the one in front: Wispr pastes wherever focus is.
my_pane=$(herdr-app ls | jq -r --arg t "$HC_TERMINAL_ID" '.spaces[].tabs[].terminals[] | select(.terminal==$t) | .pane')
focus=$(herdr-app status | jq -r '.focused_pane')
listen=yes; [ -n "$my_pane" ] && [ "$my_pane" = "$focus" ] || listen=no

if [ -n "$DRY_RUN" ]; then echo "WOULD SPEAK: $text"; echo "WOULD LISTEN: $listen"; exit 0; fi
log="$cfg/last-turn.log"; { echo "== $(date +%T) listen=$listen"; } > "$log"
uvx --from voice-mode voicemode converse --skip-stt "$text" >> "$log" 2>&1
[ "$listen" = yes ] && "$HOME/.local/bin/pmlisten" --submit --wait 12 --verbose >> "$log" 2>&1
exit 0
