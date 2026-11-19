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
     \n\
     Home resolves from --home, then $FM_HOME, then the current directory.\n\
     State resolves from --state, then $FM_STATE_OVERRIDE, then <home>/state.\n\
     Config resolves from $FM_CONFIG_OVERRIDE, then <home>/config.\n"
}

struct Args {
    rest: Vec<String>,
    home: PathBuf,
    state: PathBuf,
}

fn parse_args(argv: &[String]) -> Result<Args, String> {
    let mut home: Option<PathBuf> = None;
    let mut state: Option<PathBuf> = None;
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
    Ok(Args { rest, home, state })
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
            let kind = match args.rest.get(1).map(String::as_str) {
                Some("ship" | "scout" | "secondmate") => args.rest[1].clone(),
                Some(k) if !k.is_empty() => "unknown".to_string(),
                _ => state::kind_for(path),
            };
            for d in status::open_decisions(&state::read_status_lines(path), &kind) {
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
        other => {
            eprintln!("fmd: unknown command {other}\n{}", usage());
            ExitCode::FAILURE
        }
    }
}
