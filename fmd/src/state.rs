//! State-file readers: `state/<id>.meta`, `state/<id>.status`, the
//! watcher beat, and the supervision mode config.
//!
//! fmd consumes the file contract the bash scripts write.
//! It never replaces it: readers here only read.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::status::{last_event, open_decisions, verb, OpenDecision};

/// Ordered `key=value` meta record. Later duplicate keys win, matching
/// the bash readers that scan the whole file and keep the last match.
pub fn read_meta(path: &Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in read_lines(path) {
        if let Some((k, v)) = line.split_once('=') {
            out.insert(k.to_string(), v.to_string());
        }
    }
    out
}

/// Lines split on LF only, like bash `read -r`: a CR stays in the line,
/// and a final line without a newline still counts.
pub fn read_lines(path: &Path) -> Vec<String> {
    let Ok(bytes) = fs::read(path) else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();
    if lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines
}

fn is_plain_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_file())
}

/// Status lines for the fold. Mirrors `status_open_decisions`: a missing,
/// unreadable, or symlinked status file reads as empty.
pub fn read_status_lines(path: &Path) -> Vec<String> {
    if !is_plain_file(path) {
        return Vec::new();
    }
    read_lines(path)
}

/// Sibling meta path. Mirrors bash `${status%.status}.meta`.
pub fn meta_path(status_path: &Path) -> PathBuf {
    let s = status_path.to_string_lossy();
    PathBuf::from(format!("{}.meta", s.strip_suffix(".status").unwrap_or(&s)))
}

/// Task kind for the decision fold. Mirrors `_fm_status_kind`: an absent,
/// unreadable, or symlinked meta yields `unknown`, a meta without a
/// nonempty `kind=` yields `ship`, and only ship/scout/secondmate survive.
pub fn kind_for(status_path: &Path) -> String {
    let path = meta_path(status_path);
    if !is_plain_file(&path) || fs::File::open(&path).is_err() {
        return "unknown".to_string();
    }
    let meta = read_meta(&path);
    let kind = match meta.get("kind").map(String::as_str) {
        Some(k) if !k.is_empty() => k,
        _ => "ship",
    };
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
        let meta = read_meta(&meta_path(&status_path));
        let kind = kind_for(&status_path);
        let lines = read_status_lines(&status_path);
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

/// Supervision mode from `<config>/supervision`, where `<config>` is a
/// nonempty `$FM_CONFIG_OVERRIDE`, else `<home>/config`.
/// The raw first line must be exactly `shadow` or `fmd`, with no trimming,
/// matching `fm_fmd_mode` in `bin/fm-fmd-seam.sh`.
/// Anything else, including a missing file, is `legacy`, so bash stays
/// the default and the fallback.
pub fn supervision_mode(home: &Path) -> String {
    let config = match std::env::var_os("FM_CONFIG_OVERRIDE") {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => home.join("config"),
    };
    let lines = read_lines(&config.join("supervision"));
    match lines.first().map(String::as_str).unwrap_or("") {
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
    fn kind_empty_is_ship_and_symlink_is_unknown() {
        let dir = std::env::temp_dir().join(format!("fmd-kind-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.meta"), "kind=\n").unwrap();
        assert_eq!(kind_for(&dir.join("a.status")), "ship");
        std::os::unix::fs::symlink(dir.join("a.meta"), dir.join("b.meta")).unwrap();
        assert_eq!(kind_for(&dir.join("b.status")), "unknown");
        assert_eq!(kind_for(&dir.join("c.status")), "unknown");
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
        fs::write(dir.join("config/supervision"), "fmd \n").unwrap();
        assert_eq!(supervision_mode(&dir), "legacy");
        fs::write(dir.join("config/supervision"), "fmd\r\n").unwrap();
        assert_eq!(supervision_mode(&dir), "legacy");
        fs::write(dir.join("config/supervision"), "fmd").unwrap();
        assert_eq!(supervision_mode(&dir), "fmd");
        fs::remove_dir_all(&dir).unwrap();
    }
}
