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
    let out = Command::new(env!("CARGO_BIN_EXE_fmd"))
        .args(args)
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
fn mode_defaults_legacy() {
    let dir = std::env::temp_dir().join(format!("fmd-cli-mode-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = run(&["mode", "--home", &dir.to_string_lossy()]);
    assert_eq!(out.trim(), "legacy");
    std::fs::remove_dir_all(&dir).unwrap();
}
