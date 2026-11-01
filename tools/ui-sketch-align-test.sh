#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# check-all sources: app/sketch app/commands/SketchCommands.cpp app/MainWindow.cpp tools/cli
# check-all sources: core/sketch core/model-api/src/sketch.rs
# Alignment guides while drawing, through the real UI, on a design
# mitcad-cli makes: Sketch1 on XY with a line from A (21.37, 33.71) to
# B (47.13, 12.29), off the grid.
#   1. With the Line tool, the pointer 3 pixels beside the vertical through
#      A, below it, takes A's x; the grid still rounds its y.
#   2. Plumb with A and level with B (3 pixels off each): the crossing,
#      (21.37, 12.29). The view is captured with the dashed guides.
#   3. A click there starts a line at the crossing; a click at
#      (35, 30) ends it.
#   4. 12 pixels off: no alignment. The saved line starts at A's x and B's
#      y.
#
# Runs headless on Xvfb (see ui-test-lib.sh).
# Usage: tools/ui-sketch-align-test.sh

source "$(dirname "$0")/ui-test-lib.sh"

CLI=${UI_CLI:-$(cd "$(dirname "$UI_APP")/.." && pwd)/tools/cli/mitcad-cli}
WORK=$(mktemp -d /tmp/mitcad-ui-sketch-align.XXXXXX)
FILE=$WORK/align.mitcad
trap 'ui_cleanup; rm -rf -- "${WORK:?}"' EXIT

cat > "$WORK/model.json" << 'EOF'
[
  {"cmd": "sketch.create"},
  {"cmd": "sketch.add_line", "sketch": "F1", "start": [21.37, 33.71], "end": [47.13, 12.29]}
]
EOF
"$CLI" run "$WORK/model.json" --save "$FILE" > "$WORK/cli.log" 2>&1 || { cat "$WORK/cli.log"; ui_fail "mitcad-cli"; }

# pointer_off x y dx dy: the pointer dx, dy pixels from the sketch point
# (x, y) mm.
pointer_off() {
  local px py
  read -r px py <<< "$(ui_sketch_at "$1" "$2")"
  xdotool mousemove $((px + $3 * UI_SCALE)) $((py + $4 * UI_SCALE))
}

# expect_place dx dy x y description: the pointer at (x, y) moved by dx, dy
# pixels is reported at exactly (x, y) (two decimals).
expect_place() {
  local place
  ui_mark
  ui_step "pointer $1, $2 px off ($3, $4)" pointer_off "$3" "$4" "$1" "$2"
  ui_expect_new "Sketch pointer x " "the pointer's place logged"
  place=$(sed -n 's/.*Sketch pointer x \([-0-9.]*\), y \([-0-9.]*\) mm.*/\1 \2/p' "$UI_LOG" | tail -1)
  echo "     reported: $place"
  [ "$place" = "$5" ] || ui_fail "$6: the view reports '$place', expected '$5'"
  echo "ok   $6"
}

ui_start_display
ui_start_app --open "$FILE"
ui_step "fit (F6)"                       ui_key F6
ui_expect_log "Timeline Sketch1 at" "the timeline is logged"
ui_step "edit Sketch1 (double-click)"    ui_double_click_logged "Timeline Sketch1"
ui_expect_log "Editing sketch F1 (Sketch1)" "Sketch1 is edited"
ui_mark
ui_step "line (search)"                  ui_command "Line"
ui_expect_new "Sketch tool Line" "Line active"

echo "--- 1. Plumb with A"
# 25 mm is on the grid at any step the view shows, and far from the line.
expect_place 3 0 21.37 25 "21.37 25.00" "A's x, the grid's y"

echo "--- 2. Plumb with A, level with B"
expect_place 3 -3 21.37 12.29 "21.37 12.29" "the crossing of the two guides"
ui_sync
[ -z "${UI_SHOT:-}" ] || ui_capture "$UI_SHOT"

echo "--- 3. A line from the crossing"
ui_mark
ui_step "click at the crossing"          pointer_off 21.37 12.29 3 -3
xdotool click 1
ui_step "end at (35, 30)"                ui_sketch_click 35 30
ui_expect_new "Added line c" "the line is drawn"

echo "--- 4. Too far off: the grid"
ui_mark
ui_step "pointer 12 px off A's vertical" pointer_off 21.37 25 12 0
ui_expect_new "Sketch pointer x " "the pointer's place logged"
place=$(sed -n 's/.*Sketch pointer x \([-0-9.]*\), y \([-0-9.]*\) mm.*/\1 \2/p' "$UI_LOG" | tail -1)
echo "     reported: $place"
[ "${place%% *}" != 21.37 ] || ui_fail "aligned 12 px off: $place"
echo "ok   no alignment 12 px off"
ui_step "end the chain (Esc)"            ui_key Escape
ui_step "end the tool (Esc)"             ui_key Escape
ui_step "finish sketch (Ctrl+Enter)"     ui_key ctrl+Return
ui_expect_log "Sketch finished" "Sketch1 finished"
ui_mark
ui_step "save (Ctrl+S)"                  ui_key ctrl+s
ui_expect_new "Saved $FILE" "the design is saved"
actual=$(jq -c '[.features[0].entities[] | select(.type == "point") | .at
  | select(((.[0] - 21.37) | fabs) < 1e-6 and ((.[1] - 12.29) | fabs) < 1e-6)] | length' "$FILE") ||
  ui_fail "cannot read $FILE"
[ "$actual" = 1 ] || ui_fail "$actual points at (21.37, 12.29), expected 1"
echo "ok   the line starts at A's x and B's y"

ui_finish "sketch alignment guides"
