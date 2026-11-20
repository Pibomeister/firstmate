#!/usr/bin/env bash
# Local deterministic seat: no model call. Reads the prompt and answers decline.
cat >/dev/null
printf '{"choice":"decline","rationale":"local test seat"}\n'
