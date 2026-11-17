#!/usr/bin/env bash
# fm-reset-audit.sh - local mission-state continuity audit across a reset.
#
# Usage:
#   fm-reset-audit.sh snapshot [--out <file>]
#   fm-reset-audit.sh compare --before <file> [--after <file>]
#                     [--kind compaction|handoff] [--strict|--no-strict]
#
# FM_HOME selects the home (default: the code root). Node and tasks-axi are
# required. Directory overrides and inherited TASKS_AXI_* addressing are ignored:
# every mission record belongs to this home. No network or harness is invoked.
# Local markdown and Beads backlogs use fm-tasks-axi.sh's read-only interface.
# A configured markdown Done archive must also resolve inside this home.
#
# snapshot emits deterministic version-1 JSON, with sorted open goal, captain
# hold, task metadata (id, branch, pr, spawn_gen), and queued/in-flight item
# inventories. It also includes terminal goal, Done, and hold-resolution evidence
# so compare --after is entirely offline and does not consult live state.
# Captures are point-in-time observations, not a transaction with fleet writers;
# take snapshots at a quiet reset boundary, and retry a raced audit.
#
# compare requires the same canonical home in both manifests. Surviving IDs and
# durable terminal transitions account for prior work. A hold release needs a
# newer recorded resolution, never merely Done or unhold. A missing task needs
# Done evidence; a worker's done status alone is not teardown. Branch/PR updates
# on a surviving task are allowed. Missing backlog work also produces DRIFT.
# Existing markdown Done archives supply completion and resolution evidence.
#
# Each compare appends one TSV row to <home>/state/reset-audit.tsv:
#   <epoch> <kind> <PASS|FAIL> <comma-separated category:id drift, or ->
# Fields are TAB-separated. The newest 100 rows are retained, under a local
# exclusive lock, by atomic replacement. Concurrent compares refuse (exit 2).
# Strict mode is the default: DRIFT prints FAIL and exits 1. --no-strict still
# records FAIL but exits 0. PASS exits 0; usage/read/schema errors exit 2 and
# never record a successful audit. --kind defaults to compaction.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac
exec node - "$SCRIPT_DIR" "$@" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const [scripts, command, ...args] = process.argv.slice(2);
const fail = message => { throw new Error(message); };
const slug = value => typeof value === 'string' && /^[A-Za-z0-9._-]+$/.test(value);
const sorted = rows => rows.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const canonical = value => JSON.stringify(value, null, 2) + '\n';
const opts = {};
try {
  if (!['snapshot', 'compare'].includes(command)) fail('expected snapshot or compare; see --help');
  const allowed = command === 'snapshot' ? ['--out'] : ['--before', '--after', '--kind'];
  let strict = true;
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (command === 'compare' && ['--strict', '--no-strict'].includes(flag)) {
      if ('strict' in opts) fail('repeated strict option');
      opts.strict = true;
      strict = flag === '--strict';
    } else {
      if (!allowed.includes(flag) || flag in opts || !args[i + 1] || args[i + 1].startsWith('--'))
        fail(`invalid or missing option: ${flag}`);
      opts[flag] = args[++i];
    }
  }
  const home = fs.realpathSync(process.env.FM_HOME || path.dirname(scripts));
  const inside = file => {
    let probe = path.resolve(file);
    while (!fs.existsSync(probe)) {
      try { if (fs.lstatSync(probe).isSymbolicLink()) fail(`unsafe path: ${file}`); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      probe = path.dirname(probe);
    }
    const real = fs.realpathSync(probe);
    if (real !== home && !real.startsWith(home + path.sep)) fail(`outside FM_HOME: ${file}`);
    return file;
  };
  const read = file => {
    inside(file);
    try { return fs.readFileSync(file, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') return ''; throw error; }
  };
  // TOON rows use JSON quoted strings, including escaped commas and newlines.
  // Validate table counts so a partial/tool-error listing cannot erase work.
  function table(output) {
    const lines = output.split('\n');
    const index = lines.findIndex(line => /^tasks\[\d+\]\{.*\}:$/.test(line));
    if (index < 0) {
      if (/^count: 0$/m.test(output) && /^tasks: 0 (?:\w+ )*tasks in this backlog$/m.test(output)) return [];
      fail('unreadable backlog listing');
    }
    const [, count, names] = lines[index].match(/^tasks\[(\d+)\]\{(.*)\}:$/);
    const columns = names.split(',');
    if (!['id', 'state', 'body', 'hold_kind', 'held'].every(name => columns.includes(name))) fail('incomplete backlog schema');
    const rows = [];
    for (const line of lines.slice(index + 1, index + 1 + Number(count))) {
      if (!line.startsWith('  ')) fail('incomplete backlog listing');
      const tokens = line.slice(2).match(/"(?:\\.|[^"\\])*"|[^,]+|(?<=,)(?=,|$)/g) || [];
      if (tokens.length !== columns.length) fail('malformed backlog row');
      const values = tokens.map(token => token.startsWith('"') ? JSON.parse(token) : token);
      const row = Object.fromEntries(columns.map((name, i) => [name, values[i]]));
      if (!slug(row.id) || !['queued', 'in_flight', 'done'].includes(row.state)) fail('invalid backlog identity/state');
      rows.push(row);
    }
    return rows;
  }
  const env = { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: path.join(home, 'data'),
    FM_STATE_OVERRIDE: path.join(home, 'state'), FM_CONFIG_OVERRIDE: path.join(home, 'config') };
  delete env.TASKS_AXI_FILE;
  delete env.TASKS_AXI_BACKEND;
  let backend;
  function tasks(...argv) {
    if (!backend) {
      backend = execFileSync('bash', ['-c', '. "$1/fm-tasks-axi-lib.sh"; fm_tasks_axi_backend_resolve "$2"',
        'reset-audit', scripts, home], { env, encoding: 'utf8', timeout: 10000 }).trim();
      if (!['markdown', 'beads'].includes(backend)) fail(`non-local or unsupported backlog backend: ${backend}`);
      if (backend === 'beads') inside(path.join(home, '.beads'));
      env.TASKS_AXI_BACKEND = backend;
    }
    return execFileSync('bash', [path.join(scripts, 'fm-tasks-axi.sh'), ...argv],
      { env, cwd: home, encoding: 'utf8', timeout: 10000, maxBuffer: 16 * 1024 * 1024 });
  }
  function resolutionCount(body) {
    // Match the same legacy/current record markers as captain-hold's reader.
    if (!/^(?:Captain decision|Reconciliation evidence):/m.test(body)) return 0;
    return (body.match(/^Resolution recorded by fm-(?:captain|decision)-hold\.$/gm) || []).length;
  }
  function snapshot() {
    const goals = new Map();
    for (const line of read(path.join(home, 'state/dispatch-log.tsv')).split('\n').filter(Boolean)) {
      const fields = line.split('\t');
      if (fields.length < 5 || !slug(fields[3]) || !['received', 'queued', 'dispatched', 'blocked'].includes(fields[2])) fail('malformed dispatch ledger');
      goals.set(fields[3], { id: fields[3], event: fields[2] });
    }
    inside(path.join(home, 'data'));
    inside(path.join(home, 'data/backlog.md'));
    inside(path.join(home, '.tasks.toml'));
    const rows = fs.existsSync(path.join(home, 'data')) ? table(tasks('list', '--fields', 'body,hold_kind,held')).filter(row => row.state !== 'done') : [];
    const done = fs.existsSync(path.join(home, 'data')) ? table(tasks('list', '--state', 'done', '--fields', 'body,hold_kind,held')) : [];
    const holds = [], resolutions = [];
    for (const row of [...rows, ...done]) {
      let body = row.body || '';
      if (/\.\.\. \(truncated, [0-9]+ chars total/.test(body)) {
        const shown = tasks('show', row.id, '--full');
        const match = shown.match(/^  body: (.*)$/m);
        if (!match) fail(`unreadable task body: ${row.id}`);
        body = match[1].startsWith('"') ? JSON.parse(match[1]) : match[1];
      }
      const count = resolutionCount(body);
      if (count) resolutions.push({ id: row.id, count });
      if (row.state !== 'done' && row.hold_kind === 'captain') {
        holds.push({ id: row.id, set: body.match(/^Captain hold set: (.*)$/m)?.[1] || '', resolutions: count });
      }
    }
    // Done retention appends normal markdown rows. Read only the newest block
    // per ID, and never let an old archive override a current live item.
    // Configuration may be global; mission records must stay in this home.
    const globalConfig = path.join(require('node:os').homedir(), '.tasks-axi/config.toml');
    const globalSettings = fs.existsSync(globalConfig) ? fs.readFileSync(globalConfig, 'utf8') : '';
    const settings = globalSettings + '\n[reset-audit-boundary]\n' + read(path.join(home, '.tasks.toml'));
    let section = '', archive = path.join(home, 'data/done-archive.md');
    for (const line of settings.split('\n')) {
      const heading = line.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/);
      if (heading) section = heading[1];
      if (section === 'markdown' && /^\s*archive\s*=/.test(line)) {
        const value = line.match(/^\s*archive\s*=\s*("(?:\\.|[^"\\])*"|'[^']*')\s*(?:#.*)?$/)?.[1];
        if (!value) fail('unsupported markdown archive setting');
        // tasks-axi treats both quote types literally, without TOML escapes.
        archive = path.resolve(home, value.slice(1, -1));
      }
    }
    const archived = new Map();
    let current;
    for (const line of (backend === 'beads' ? '' : read(archive)).split('\n')) {
      const match = line.match(/^- \[x\] ([A-Za-z0-9._-]+)(?: |$)/);
      if (match) { current = { id: match[1], body: '' }; archived.set(current.id, current); }
      else if (current && (line === '' || /^\s/.test(line))) current.body += line.replace(/^  /, '') + '\n';
      else current = undefined;
    }
    for (const row of archived.values()) {
      if ([...rows, ...done].some(item => item.id === row.id)) continue;
      const count = resolutionCount(row.body);
      if (count) resolutions.push({ id: row.id, count });
    }
    const metas = fs.existsSync(path.join(home, 'state')) ? fs.readdirSync(path.join(home, 'state')).filter(name => name.endsWith('.meta') && !name.startsWith('.')) : [];
    const active = metas.map(name => {
      const id = name.slice(0, -5);
      if (!slug(id)) fail(`invalid metadata id: ${id}`);
      const values = Object.fromEntries(read(path.join(home, 'state', name)).split('\n').filter(line => line.includes('=')).map(line => {
        const index = line.indexOf('='); return [line.slice(0, index), line.slice(index + 1)];
      }));
      return { id, branch: values.branch || '', pr: values.pr || '', spawn_gen: values.spawn_gen || '' };
    });
    return { version: 1, home, goals: sorted([...goals.values()].filter(row => ['received', 'queued'].includes(row.event))),
      holds: sorted(holds), tasks: sorted(active), backlog: sorted(rows.filter(row => row.state !== 'done').map(({ id, state }) => ({ id, state }))),
      evidence: { goals: sorted([...goals.values()].filter(row => ['dispatched', 'blocked'].includes(row.event))),
        done: [...new Set([...done, ...archived.values()].filter(row => !rows.some(item => item.id === row.id)).map(row => row.id))].sort(), resolutions: sorted(resolutions) } };
  }
  function validate(value) {
    if (value?.version !== 1 || value.home !== home) fail('manifest version/home mismatch');
    for (const name of ['goals', 'holds', 'tasks', 'backlog']) {
      if (!Array.isArray(value[name]) || value[name].some(row => !slug(row?.id)) || new Set(value[name].map(row => row.id)).size !== value[name].length)
        fail(`invalid manifest ${name}`);
    }
    if (value.goals.some(row => !['received', 'queued'].includes(row.event)) ||
        value.backlog.some(row => !['queued', 'in_flight'].includes(row.state)) ||
        value.tasks.some(row => ['branch', 'pr', 'spawn_gen'].some(key => typeof row[key] !== 'string')))
      fail('invalid manifest state');
    if (value.goals.some(row => !['received', 'queued'].includes(row.event)) ||
        value.backlog.some(row => !['queued', 'in_flight'].includes(row.state)) ||
        value.tasks.some(row => !['branch', 'pr', 'spawn_gen'].every(key => typeof row[key] === 'string')))
      fail('invalid manifest work state');
    const evidence = value.evidence;
    if (!evidence || !Array.isArray(evidence.goals) || evidence.goals.some(row => !slug(row?.id) || !['dispatched', 'blocked'].includes(row.event)) ||
        !Array.isArray(evidence.done) || evidence.done.some(id => !slug(id)) || !Array.isArray(evidence.resolutions) ||
        evidence.resolutions.some(row => !slug(row?.id) || !Number.isInteger(row.count) || row.count < 1) ||
        value.holds.some(row => !Number.isInteger(row.resolutions) || row.resolutions < 0)) fail('invalid manifest evidence');
    return value;
  }
  if (command === 'snapshot') {
    const output = canonical(snapshot());
    if (opts['--out']) fs.writeFileSync(opts['--out'], output, { mode: 0o600 });
    else process.stdout.write(output);
  } else {
    if (!opts['--before']) fail('--before is required');
    const kind = opts['--kind'] || 'compaction';
    if (!['compaction', 'handoff'].includes(kind)) fail('invalid reset kind');
    const before = validate(JSON.parse(fs.readFileSync(opts['--before'], 'utf8')));
    const after = validate(opts['--after'] ? JSON.parse(fs.readFileSync(opts['--after'], 'utf8')) : snapshot());
    const has = (rows, id) => rows.some(row => row.id === id);
    const drift = [];
    for (const row of before.goals)
      if (!has(after.goals, row.id) && !has(after.evidence.goals, row.id)) drift.push(`goal:${row.id}`);
    for (const row of before.holds)
      if (!has(after.holds, row.id) && !after.evidence.resolutions.some(item => item.id === row.id && item.count > row.resolutions)) drift.push(`hold:${row.id}`);
    for (const row of before.tasks)
      if (!has(after.tasks, row.id) && !after.evidence.done.includes(row.id)) drift.push(`task:${row.id}`);
    for (const row of before.backlog)
      if (!has(after.backlog, row.id) && !after.evidence.done.includes(row.id)) drift.push(`backlog:${row.id}`);
    drift.sort();
    const verdict = drift.length ? 'FAIL' : 'PASS';
    const state = inside(path.join(home, 'state'));
    fs.mkdirSync(state, { recursive: true });
    const log = inside(path.join(state, 'reset-audit.tsv'));
    const lock = inside(path.join(state, '.reset-audit.lock'));
    const fd = fs.openSync(lock, 'wx', 0o600);
    let temporary;
    try {
      const prior = read(log).split('\n').filter(Boolean).slice(-99);
      prior.push(`${Math.floor(Date.now() / 1000)}\t${kind}\t${verdict}\t${drift.join(',') || '-'}`);
      temporary = path.join(state, `.reset-audit.${process.pid}.tmp`);
      fs.writeFileSync(temporary, prior.join('\n') + '\n', { flag: 'wx', mode: 0o600 });
      fs.renameSync(temporary, log);
    } finally {
      fs.closeSync(fd);
      fs.unlinkSync(lock);
      if (temporary && fs.existsSync(temporary)) fs.unlinkSync(temporary);
    }
    console.log(`${verdict} kind=${kind}${drift.length ? ' DRIFT ' + drift.join(',') : ''}`);
    if (strict && drift.length) process.exitCode = 1;
  }
} catch (error) {
  console.error(`fm-reset-audit: ${error.message}`);
  process.exitCode = 2;
}
NODE
