Test phase: NO-GO.

At unchanged head 7e48f6291acb1e9b54670ccf525ba69c4944601b, the real product called Claude Code 2.1.331 with the existing haiku model and fixed no-tools argv. Safe mode excluded instructions/plugins/hooks while preserving native authentication. Only the recorded synthetic input was supplied. After 121.19 seconds the product reported summary unavailable. Runner stdout and stderr were empty; no served-model provenance or summary was returned. Cause remains undetermined; no product repair is justified by this observation. No provider/account/model fallback was attempted.

Native LaunchAgent registration was not attempted. Exact phase restriction: "Do not modify system state outside the worktree." Prior finding guidance explicitly requires preserving that refusal rather than bypassing it. No job was registered or removed.

Prior seven scenario results are retained as prior evidence, not fresh passes: same head and unchanged source tree; prior command inputs remain in ../live-driver.py. This turn ran only the focused outstanding model criterion. No source or test files were modified. The disposable fixture was removed after the process check.
