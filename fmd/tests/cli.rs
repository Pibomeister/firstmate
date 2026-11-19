use std::path::PathBuf;
use std::process::Command;

fn fixture(name: &str) -> String {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures")
        .join(name)
        .to_string_lossy()
        .to_string()
}

fn run(args: &[&str]) -> String {
    run_env(args, &[])
}

fn run_env(args: &[&str], env: &[(&str, &str)]) -> String {
    let out = Command::new(env!("CARGO_BIN_EXE_fmd"))
        .args(args)
        .env_remove("FM_CLASSIFY_RESOLVE_VERB")
        .env_remove("FM_CLASSIFY_CAPTAIN_HELD_VERB")
        .env_remove("FM_CLASSIFY_RESERVED_KEY_PREFIXES")
        .env_remove("FM_CONFIG_OVERRIDE")
        .envs(env.iter().copied())
        .output()
        .expect("run fmd");
    assert!(out.status.success(), "fmd {args:?} failed: {out:?}");
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

#[test]
fn open_decisions_fixture() {
    let out = run(&["open-decisions", &fixture("open-decisions.status")]);
    assert!(out.contains("creds\tblocked\tcredential missing"), "{out}");
    assert!(
        out.contains("note-head\tneeds-decision\tchoose the note form"),
        "{out}"
    );
    assert!(
        out.contains("pending-reply-y\tblocked\tpending-reply-missed:"),
        "{out}"
    );
    assert!(!out.contains("api-1"), "resolved key must close: {out}");
    assert!(
        !out.contains("pending-reply-x"),
        "reserved key needs its vocabulary: {out}"
    );
}

#[test]
fn terminal_ship_clears_open() {
    let out = run(&["open-decisions", &fixture("terminal.status")]);
    assert_eq!(out, "");
    let out = run(&["open-decisions", &fixture("terminal.status"), "secondmate"]);
    assert!(out.contains("stuck\tblocked\t"), "{out}");
}

#[test]
fn meta_and_last_event() {
    let out = run(&["meta", &fixture("open-decisions.meta")]);
    assert!(out.contains("kind\tship"), "{out}");
    let out = run(&["last-event", &fixture("terminal.status")]);
    assert!(out.starts_with("done [at=200]:"), "{out}");
}

#[test]
fn parity_edges_fixture() {
    let out = run(&["open-decisions", &fixture("parity-edges.status")]);
    assert!(out.contains("corr-a\tneeds-decision\t"), "{out}");
    assert!(!out.contains("corr-b"), "exact corr token closes: {out}");
    assert!(out.contains("corr-c\tneeds-decision\t"), "{out}");
    assert!(!out.contains("unclosed"), "incomplete key token: {out}");
    assert!(out.contains("colonless\tblocked\t"), "{out}");
    assert!(
        out.contains("crlf\tblocked\tnote keeps its CR\r\n"),
        "{out:?}"
    );
}

#[test]
fn kind_and_symlink_rules() {
    assert_eq!(run(&["open-decisions", &fixture("empty-kind.status")]), "");
    let out = run(&["open-decisions", &fixture("symlink-meta.status")]);
    assert!(out.contains("stuck\tblocked\t"), "{out}");
    assert_eq!(
        run(&["open-decisions", &fixture("symlink-status.status")]),
        ""
    );
}

#[test]
fn classify_overrides_are_honored() {
    let file = fixture("overrides.status");
    let out = run(&["open-decisions", &file]);
    assert!(out.contains("a\tblocked\t"), "{out}");
    assert!(out.contains("own-x\tblocked\t"), "{out}");
    assert!(!out.contains("pending-reply-z"), "{out}");
    let out = run_env(
        &["open-decisions", &file],
        &[
            ("FM_CLASSIFY_RESOLVE_VERB", "answered"),
            ("FM_CLASSIFY_CAPTAIN_HELD_VERB", "parked"),
            ("FM_CLASSIFY_RESERVED_KEY_PREFIXES", "own-"),
        ],
    );
    assert!(!out.contains("a\tblocked"), "{out}");
    assert!(!out.contains("b\tblocked"), "{out}");
    assert!(!out.contains("own-x"), "{out}");
    assert!(out.contains("pending-reply-z\tblocked\t"), "{out}");
}

#[test]
fn mode_honors_config_override() {
    let dir = std::env::temp_dir().join(format!("fmd-cli-override-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("over")).unwrap();
    std::fs::write(dir.join("over/supervision"), "fmd\n").unwrap();
    let over = dir.join("over").to_string_lossy().to_string();
    let home = dir.to_string_lossy().to_string();
    let out = run_env(&["mode", "--home", &home], &[("FM_CONFIG_OVERRIDE", &over)]);
    assert_eq!(out, "fmd\n");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn mode_defaults_legacy() {
    let dir = std::env::temp_dir().join(format!("fmd-cli-mode-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = run(&["mode", "--home", &dir.to_string_lossy()]);
    assert_eq!(out.trim(), "legacy");
    std::fs::remove_dir_all(&dir).unwrap();
}
