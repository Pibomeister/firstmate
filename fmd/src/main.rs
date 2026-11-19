//! fmd - opt-in Firstmate supervision sidecar (Rust, std only).
//!
//! Slice 1: scaffold plus state readers with parity tests.
//! Bash remains the default and the fallback (`supervision=legacy`).
//! The event-driven daemon loop (S11/S12), admission gate (S13), and
//! compiled hot paths (S14) land as later small slices; see fmd/README.md.

mod state;
mod status;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

fn usage() -> &'static str {
    "fmd - opt-in Firstmate supervision sidecar\n\
     \n\
     Usage:\n\
     \x20 fmd mode --home <FM_HOME>\n\
     \x20 fmd open-decisions <state/<id>.status> [ship|scout|secondmate|unknown]\n\
     \x20 fmd last-event <state/<id>.status>\n\
     \x20 fmd meta <state/<id>.meta>\n\
     \x20 fmd snapshot --home <FM_HOME> [--state <dir>]\n\
     \x20 fmd check --home <FM_HOME> [--state <dir>]\n\
     \x20 fmd beat --home <FM_HOME> [--state <dir>]\n\
     \x20 fmd watch --home <FM_HOME> [--state <dir>] [--once] [--interval-secs N]\n\
     \n\
     Home resolves from --home, then $FM_HOME, then the current directory.\n\
     State resolves from --state, then $FM_STATE_OVERRIDE, then <home>/state.\n"
}

struct Args {
    rest: Vec<String>,
    home: PathBuf,
    state: PathBuf,
    once: bool,
    interval_secs: u64,
}

fn parse_args(argv: &[String]) -> Result<Args, String> {
    let mut home: Option<PathBuf> = None;
    let mut state: Option<PathBuf> = None;
    let mut once = false;
    let mut interval_secs: u64 = 15;
    let mut rest: Vec<String> = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        match argv[i].as_str() {
            "--home" => {
                i += 1;
                home = Some(PathBuf::from(argv.get(i).ok_or("--home needs a value")?));
            }
            "--state" => {
                i += 1;
                state = Some(PathBuf::from(argv.get(i).ok_or("--state needs a value")?));
            }
            "--interval-secs" => {
                i += 1;
                let v = argv.get(i).ok_or("--interval-secs needs a value")?;
                interval_secs = v.parse().map_err(|_| "bad --interval-secs")?;
                if interval_secs == 0 {
                    return Err("--interval-secs must be positive".into());
                }
            }
            "--once" => once = true,
            other => rest.push(other.to_string()),
        }
        i += 1;
    }
    let home = home
        .or_else(|| std::env::var_os("FM_HOME").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."));
    let state = state
        .or_else(|| std::env::var_os("FM_STATE_OVERRIDE").map(PathBuf::from))
        .unwrap_or_else(|| home.join("state"));
    Ok(Args {
        rest,
        home,
        state,
        once,
        interval_secs,
    })
}

fn print_snapshot(state_dir: &Path) {
    for row in state::snapshot(state_dir) {
        let last_at = status::at_epoch(&row.last_event)
            .map(|e| e.to_string())
            .unwrap_or_else(|| "-".to_string());
        let branch = row.meta.get("branch").map(String::as_str).unwrap_or("-");
        println!(
            "{}\tkind={}\tlast_verb={}\tlast_at={}\tbranch={}\topen={}",
            row.id,
            row.kind,
            if row.last_verb.is_empty() {
                "-"
            } else {
                &row.last_verb
            },
            last_at,
            branch,
            row.open.len()
        );
        for d in &row.open {
            println!("{}\topen\t{}\t{}\t{}", row.id, d.key, d.verb, d.note);
        }
    }
}

fn cmd_check(args: &Args) -> ExitCode {
    let mode = state::supervision_mode(&args.home);
    let rows = state::snapshot(&args.state);
    let open: usize = rows.iter().map(|r| r.open.len()).sum();
    let beat = match state::beat_age_seconds(&args.state) {
        Some(s) => s.to_string(),
        None => "unknown".to_string(),
    };
    println!(
        "fmd-check: mode={mode} tasks={} open_decisions={open} beat_age_seconds={beat}",
        rows.len()
    );
    if !args.state.is_dir() {
        eprintln!("fmd-check: state dir missing: {}", args.state.display());
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn cmd_watch(args: &Args) -> ExitCode {
    // Polling watch for this slice. It touches only fmd's own beat file,
    // never the bash watcher's `.last-watcher-beat`, so running it beside
    // legacy supervision cannot fake bash liveness.
    loop {
        print_snapshot(&args.state);
        let beat = args.state.join(".fmd-beat");
        let _ = std::fs::write(&beat, format!("{}\n", state::now_epoch()));
        if args.once {
            return ExitCode::SUCCESS;
        }
        std::thread::sleep(Duration::from_secs(args.interval_secs));
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() || matches!(argv[0].as_str(), "--help" | "-h" | "help") {
        print!("{}", usage());
        return ExitCode::SUCCESS;
    }
    let command = argv[0].clone();
    let args = match parse_args(&argv[1..]) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fmd: {e}\n{}", usage());
            return ExitCode::FAILURE;
        }
    };
    match command.as_str() {
        "mode" => {
            println!("{}", state::supervision_mode(&args.home));
            ExitCode::SUCCESS
        }
        "open-decisions" => {
            let Some(file) = args.rest.first() else {
                eprintln!("fmd: open-decisions needs a status file");
                return ExitCode::FAILURE;
            };
            let path = Path::new(file);
            let meta = state::read_meta(&path.with_extension("meta"));
            let kind = match args.rest.get(1) {
                Some(k) => match k.as_str() {
                    "ship" | "scout" | "secondmate" => k.clone(),
                    _ => "unknown".to_string(),
                },
                None => state::kind_for(path, &meta),
            };
            for d in status::open_decisions(&state::read_lines(path), &kind) {
                println!("{}\t{}\t{}", d.key, d.verb, d.note);
            }
            ExitCode::SUCCESS
        }
        "last-event" => {
            let Some(file) = args.rest.first() else {
                eprintln!("fmd: last-event needs a status file");
                return ExitCode::FAILURE;
            };
            let lines = state::read_lines(Path::new(file));
            if let Some(line) = status::last_event(&lines) {
                println!("{line}");
            }
            ExitCode::SUCCESS
        }
        "meta" => {
            let Some(file) = args.rest.first() else {
                eprintln!("fmd: meta needs a meta file");
                return ExitCode::FAILURE;
            };
            for (k, v) in state::read_meta(Path::new(file)) {
                println!("{k}\t{v}");
            }
            ExitCode::SUCCESS
        }
        "snapshot" => {
            print_snapshot(&args.state);
            ExitCode::SUCCESS
        }
        "check" => cmd_check(&args),
        "beat" => {
            match state::beat_age_seconds(&args.state) {
                Some(s) => println!("beat_age_seconds={s}"),
                None => println!("beat_age_seconds=unknown"),
            }
            ExitCode::SUCCESS
        }
        "watch" => cmd_watch(&args),
        other => {
            eprintln!("fmd: unknown command {other}\n{}", usage());
            ExitCode::FAILURE
        }
    }
}
