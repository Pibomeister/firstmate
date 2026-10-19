#!/bin/sh
exec /opt/homebrew/bin/codex --no-daemon -c check_for_update_on_startup=false -c 'projects."/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5ANWPANR7DV27YPXEKK8Q4R/.nm-live/fixture-project".trust_level="trusted"' -c 'projects."/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5ANWPANR7DV27YPXEKK8Q4R/.nm-live/fixture-worktree".trust_level="trusted"' "$@"
