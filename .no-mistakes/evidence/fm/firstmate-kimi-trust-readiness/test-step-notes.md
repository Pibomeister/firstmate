# Test-step evidence

Target: 831a081628cdb75dfacad909a9f51b364d6854e6 plus the one-line status timestamp normalization in tests/fm-kimi-harness.test.sh.
Base reproduction: d616fdd2c75f19c9fc01583adb4815a28f47ad3f, archived inside the worktree and driven through its real fm-spawn.sh.

The full focused Kimi harness script first failed because system Python lacks tomllib. A Python 3.13.9 runtime was downloaded inside the disposable worktree tool directory with uv. The focused script then exposed a status assertion that expected `failed:` where the public status format is `failed [at=<epoch>]:`. The assertion now normalizes that timestamp as the preceding version did. The final focused run exited 0. See kimi-targeted-tests.log for the failure and kimi-targeted-tests-fixed.log for the completed run.

All live scenarios invoked the real fm-spawn.sh and real tmux through fm-lab-home.sh against marked disposable FM_HOME directories and fresh local git repositories. Explicit terminal sizes were 120x40, 120x10 (clipped), and 30x80 (truncated navigation hint). The driver captured changed visible frames throughout each spawn. The unresponsive scenarios stopped only the lab worker pane process tree after the real trust dialog appeared; the controller kept running. Each lab private tmux server and home was removed in its driver's finally block.

Kimi 2.3.1 came from PATH. Its host binary changed to 2.3.3 during this run without an explicit upgrade command by this agent. Subsequent checks used a workspace-local copy. Legacy 2.0.0 was downloaded from the official release into the disposable worktree directory. The script is preserved as drive-live.py; its temporary runtime locations have been removed.

No production configuration, credentials, or Casco files were copied or modified. Live trust, readiness and pointer-submission checks used a lab-readiness profile routed to unavailable localhost:1, with a disposable non-credential value. Resulting provider.connection_error messages are expected and prove no model response. No K3.1 Pro model inference or Casco design review is claimed. Exact-profile production inference would require an authorized sandbox-scoped Kimi config and credential; using production credential stores is excluded by this test boundary.

The HTML and PNG render exact recorded tmux viewport text for reviewer inspection. They are terminal reconstructions, not native screenshots. Raw captures, frame sequences, metadata, and product logs remain alongside them. No linter, static analyzer, broad suite, push, PR phase, or pipeline-control command ran.

Official configuration reference: https://moonshotai.github.io/kimi-code/en/configuration/config-files
Official legacy release: https://github.com/MoonshotAI/kimi-code/releases/tag/%40moonshot-ai/kimi-code%402.0.0
