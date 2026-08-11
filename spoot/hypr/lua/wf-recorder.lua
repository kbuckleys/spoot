-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local function record(mode)
	local output_dir = os.getenv("HOME") .. "/Videos/Captures"
	local script = [[
output_dir="]] .. output_dir .. [["
mkdir -p "$output_dir"

if pgrep -x wf-recorder >/dev/null; then
  pkill -SIGINT -x wf-recorder
  # wait for it to finalize the file before notifying
  for _ in 1 2 3 4 5; do
    pgrep -x wf-recorder >/dev/null || break
    sleep 0.2
  done
  file=$(cat "$output_dir/.active-recording" 2>/dev/null)
  if [ -n "$file" ] && [ -f "$file" ]; then
    notify-send -u low "󰕧 Recording Stopped" "$file"
  else
    notify-send "󰕧 Recording Stopped"
  fi
  rm -f "$output_dir/.active-recording"
  exit 0
fi

monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name' | head -n1)
[ -n "$monitor" ] || { notify-send "󱠑 No monitor"; exit 1; }

filename="$output_dir/$(date +'%Y-%m-%d-%H%M%S')-$monitor.mp4"
log=$(mktemp)

# h264_nvenc dropped the old named presets, so preset=lossless is rejected by
# ffmpeg and the encoder never opens. Lossless is now preset p7 + tune lossless.
# -D (continuous capture) is REQUIRED: with the default damage-based capture a
# static screen delivers too few frames, and a race in wf-recorder's audio/video
# sync drops them all, leaving an audio-only file.
args=(-D -r 60 -c h264_nvenc -p preset=p7 -p tune=hq -p rc=vbr -p cq=20 -p b:v=0)

# An empty --audio= aborts inside libpulse and leaves a truncated file behind,
# so only ask for audio once a monitor source is actually known to exist
audio=$(pactl list short sources 2>/dev/null | awk '$2 ~ /\.monitor$/ {print $2; exit}')
[ -n "$audio" ] && args+=(--audio="$audio")

case "${1}" in
  full)
    args+=(-o "$monitor")
    notify-send "󰑋 Full Screen" "$monitor"
    ;;
  region)
    geometry=$(slurp -d) || exit 0
    [ -n "$geometry" ] || exit 0
    args+=(-g "$geometry")
    notify-send " Region Selected"
    ;;
  window)
    geometry=$(hyprctl -j activewindow | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')
    # jq prints the literal "null,null nullxnull" when nothing is focused, which
    # is non-empty and would sail past a -n test into a wf-recorder parse error
    [ "$geometry" != "null,null nullxnull" ] || { notify-send " No window"; exit 1; }
    args+=(-g "$geometry")
    notify-send " Window Recording"
    ;;
  *)
    notify-send -u critical "󱠑 Unknown mode" "${1}"
    exit 1
    ;;
esac

wf-recorder "${args[@]}" -f "$filename" >"$log" 2>&1 &
pid=$!

# wf-recorder gives up within a moment when the codec or geometry is rejected,
# and nothing else would surface that: the notification above has already
# claimed the recording started
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
  notify-send -u critical " Recording failed" "$(tail -n 3 "$log")"
  rm -f "$log"
  exit 1
fi
rm -f "$log"
echo "$filename" > "$output_dir/.active-recording"
]]
	hl.exec_cmd("bash -c '" .. script:gsub("'", "'\"'\"'") .. "' -- " .. mode)
end

-- BINDS
hl.bind("SUPER + R",            function() record("full") end)
hl.bind("SUPER + SHIFT + R",    function() record("window") end)
hl.bind("SUPER + CONTROL + R",  function() record("region") end)
