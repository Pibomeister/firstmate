#!/usr/bin/env bash

fm_test_fake_treehouse() {
  local fakebin=$1 project=$2 pool=$3
  mkdir -p "$fakebin"
  node -e 'require("node:fs").writeFileSync(process.argv[1], JSON.stringify({project:process.argv[2],pool:process.argv[3]}))' \
    "$fakebin/treehouse.fixture.json" "$project" "$pool"
  cat > "$fakebin/treehouse" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {project, pool} = JSON.parse(fs.readFileSync(__filename + '.fixture.json', 'utf8'));
const args = process.argv.slice(2);
const command = args[0];
const missingFile = __filename + '.missing';
const missing = fs.existsSync(missingFile) ? fs.readFileSync(missingFile, 'utf8').trim() : '';
fs.appendFileSync(__filename + '.calls', args.join(' ') + '\n');
const flags = {get:['lease','lease-holder'], lease:['lease-holder'], status:['json'], return:['force','if-lease-holder']};
if (!flags[command] || (command === 'lease' && missing === 'lease')) process.exit(1);
if (args.includes('--help')) {
  console.log(flags[command].filter(flag => command + ':' + flag !== missing).map(flag => '--' + flag).join('\n'));
  process.exit(0);
}
if (args.some(arg => command + ':' + arg.slice(2) === missing)) process.exit(1);
fs.mkdirSync(pool, {recursive:true});
const stateFile = path.join(pool, 'treehouse-state.json');
const rows = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : [];
const save = () => fs.writeFileSync(stateFile, JSON.stringify(rows));
const value = flag => { const index = args.indexOf(flag); return index < 0 ? '' : args[index + 1]; };
const git = (...argv) => execFileSync('git', argv, {stdio:['ignore','pipe','pipe']});
switch (command) {
  case 'get': {
    let row = rows.find(item => !item.lease_id);
    if (!row) {
      const name = String(rows.length + 1);
      const checkout = path.join(pool, name, path.basename(project));
      fs.mkdirSync(path.dirname(checkout), {recursive:true});
      git('-C', project, 'worktree', 'add', '--quiet', '--detach', checkout, 'HEAD');
      row = {name, path:checkout, lease_id:'', lease_holder:''};
      rows.push(row);
    }
    if (args.includes('--lease')) {
      row.lease_id = 'fixture-' + process.pid;
      row.lease_holder = value('--lease-holder') || 'fixture-dispatch';
    }
    save();
    console.log(row.path);
    break;
  }
  case 'status':
    if (!args.includes('--json')) process.exit(1);
    console.log(JSON.stringify(rows));
    break;
  case 'lease': {
    const row = rows.find(item => item.name === args[1]);
    if (!row || row.lease_id) process.exit(1);
    row.lease_id = 'fixture-' + process.pid;
    row.lease_holder = value('--lease-holder');
    save();
    console.log(row.path);
    break;
  }
  case 'return': {
    const row = rows.find(item => args.includes(item.path));
    if (!row) process.exit(1);
    if (args.includes('--if-lease-holder') && row.lease_holder !== value('--if-lease-holder')) process.exit(1);
    git('-C', row.path, 'reset', '--hard', '--quiet', 'HEAD');
    git('-C', row.path, 'clean', '-fdq');
    row.lease_id = '';
    row.lease_holder = '';
    save();
    break;
  }
}
JS
  chmod +x "$fakebin/treehouse"
}
