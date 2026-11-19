//! State-file readers: `state/<id>.meta`, `state/<id>.status`, the
//! watcher beat, and the supervision mode config.
//!
//! fmd consumes the file contract the bash scripts write.
//! It never replaces it: readers here only read, except the watch loop's
//! own `state/.fmd-beat` touch in `main.rs`.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::status::{last_event, open_decisions, verb, OpenDecision};

/// Ordered `key=value` meta record. Later duplicate keys win, matching
/// the bash readers that scan the whole file and keep the last match.
pub fn read_meta(path: &Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let Ok(text) = fs::read_to_string(path) else {
        return out;
    };
    for line in text.lines() {
        if let Some((k, v)) = line.split_once('=') {
            out.insert(k.to_string(), v.to_string());
        }
    }
    out
}

pub fn read_lines(path: &Path) -> Vec<String> {
    match fs::read_to_string(path) {
        Ok(text) => text.lines().map(str::to_string).collect(),
        Err(_) => Vec::new(),
    }
}

/// Task kind for the decision fold. Mirrors `_fm_status_kind`: an absent
/// or unreadable meta yields `unknown`, a meta without `kind=` yields
/// `ship`, and only ship/scout/secondmate survive validation.
pub fn kind_for(status_path: &Path, meta: &BTreeMap<String, String>) -> String {
    if !status_path.with_extension("meta").is_file() {
        return "unknown".to_string();
    }
    let kind = meta.get("kind").map(String::as_str).unwrap_or("ship");
    match kind {
        "ship" | "scout" | "secondmate" => kind.to_string(),
        _ => "unknown".to_string(),
    }
}

#[derive(Debug, Clone)]
pub struct TaskRow {
    pub id: String,
    pub kind: String,
    pub last_verb: String,
    pub last_event: String,
    pub open: Vec<OpenDecision>,
    pub meta: BTreeMap<String, String>,
}

/// One snapshot pass over a state directory, sorted by task id.
/// Symlinked status files are skipped, matching the directory scan in
/// `bin/fm-classify-lib.sh`.
pub fn snapshot(state_dir: &Path) -> Vec<TaskRow> {
    let mut rows = Vec::new();
    let Ok(entries) = fs::read_dir(state_dir) else {
        return rows;
    };
    let mut ids: Vec<String> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some(id) = name.strip_suffix(".status") {
            if !id.is_empty() && !id.starts_with('.') {
                ids.push(id.to_string());
            }
        }
    }
    ids.sort();
    for id in ids {
        let status_path = state_dir.join(format!("{id}.status"));
        if status_path.is_symlink() {
            continue;
        }
        let meta_path: PathBuf = state_dir.join(format!("{id}.meta"));
        let meta = read_meta(&meta_path);
        let kind = kind_for(&status_path, &meta);
        let lines = read_lines(&status_path);
        let last = last_event(&lines).unwrap_or_default();
        rows.push(TaskRow {
            id,
            kind: kind.clone(),
            last_verb: if last.is_empty() {
                String::new()
            } else {
                verb(&last)
            },
            last_event: last,
            open: open_decisions(&lines, &kind),
            meta,
        });
    }
    rows
}

/// Supervision mode from `<home>/config/supervision`.
/// The first line must be exactly `legacy`, `shadow`, or `fmd`.
/// Anything else, including a missing file, is `legacy`, so bash stays
/// the default and the fallback.
pub fn supervision_mode(home: &Path) -> String {
    let path = home.join("config").join("supervision");
    let Ok(text) = fs::read_to_string(path) else {
        return "legacy".to_string();
    };
    match text.lines().next().unwrap_or("").trim() {
        "shadow" => "shadow".to_string(),
        "fmd" => "fmd".to_string(),
        _ => "legacy".to_string(),
    }
}

/// Age in seconds of `state/.last-watcher-beat` by mtime.
/// The beat file's content is not part of the contract fmd reads.
pub fn beat_age_seconds(state_dir: &Path) -> Option<u64> {
    let meta = fs::metadata(state_dir.join(".last-watcher-beat")).ok()?;
    let modified = meta.modified().ok()?;
    let now = SystemTime::now();
    now.duration_since(modified).ok().map(|d| d.as_secs())
}

pub fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn meta_last_duplicate_wins() {
        let dir = std::env::temp_dir().join(format!("fmd-meta-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.meta");
        fs::File::create(&path)
            .unwrap()
            .write_all(b"kind=scout\nkind=ship\nbranch=fm/x\n")
            .unwrap();
        let meta = read_meta(&path);
        assert_eq!(meta["kind"], "ship");
        assert_eq!(meta["branch"], "fm/x");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn mode_defaults_to_legacy() {
        let dir = std::env::temp_dir().join(format!("fmd-mode-{}", std::process::id()));
        fs::create_dir_all(dir.join("config")).unwrap();
        assert_eq!(supervision_mode(&dir), "legacy");
        fs::write(dir.join("config/supervision"), "shadow\n").unwrap();
        assert_eq!(supervision_mode(&dir), "shadow");
        fs::write(dir.join("config/supervision"), "bogus\n").unwrap();
        assert_eq!(supervision_mode(&dir), "legacy");
        fs::remove_dir_all(&dir).unwrap();
    }
}
