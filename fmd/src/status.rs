//! Status-line parsing with parity to `bin/fm-classify-lib.sh`.
//!
//! The bash library remains the reference implementation.
//! This module mirrors only its pure text rules: stamp stripping for head
//! location, verb extraction, the well-formed `[at=...]` epoch, decision
//! keys, notes, and the whole-file open-decisions fold.

fn env_or(name: &str, default: &str) -> String {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

/// Resolution verb. Mirrors `${FM_CLASSIFY_RESOLVE_VERB:-resolved}`.
pub fn resolve_verb() -> String {
    env_or("FM_CLASSIFY_RESOLVE_VERB", "resolved")
}

/// Captain-held verb. Mirrors `${FM_CLASSIFY_CAPTAIN_HELD_VERB:-captain-held}`.
pub fn held_verb() -> String {
    env_or("FM_CLASSIFY_CAPTAIN_HELD_VERB", "captain-held")
}

fn paused_verb() -> String {
    env_or("FM_CLASSIFY_PAUSED_VERB", "paused")
}

/// Reserved key prefixes, split on whitespace like the unquoted bash list.
fn reserved_prefixes() -> Vec<String> {
    env_or(
        "FM_CLASSIFY_RESERVED_KEY_PREFIXES",
        "pending-reply- claim-refuted-",
    )
    .split(is_space)
    .filter(|w| !w.is_empty())
    .map(str::to_string)
    .collect()
}

/// POSIX `[:space:]` in the C locale.
fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
}

/// A complete `[key=...]` token: `[key=` followed later by `]`.
fn has_key_token(s: &str) -> bool {
    match s.find("[key=") {
        Some(i) => s[i..].contains(']'),
        None => false,
    }
}

/// Mirrors `_fm_classify_is_corr_token`: exactly `corr=` plus 16 hex digits.
fn is_corr_token(word: &str) -> bool {
    word.strip_prefix("corr=")
        .is_some_and(|h| h.len() == 16 && h.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Strip every `[at=...]` run that sits before the first colon.
/// Mirrors `_fm_status_unstamped`.
pub fn unstamped(line: &str) -> String {
    let mut rest = line.to_string();
    let mut keep = String::new();
    while let Some(start) = rest.find("[at=") {
        let Some(end_rel) = rest[start..].find(']') else {
            break;
        };
        let before = &rest[..start];
        if before.contains(':') {
            break;
        }
        keep.push_str(before.strip_suffix(' ').unwrap_or(before));
        rest = rest[start + end_rel + 1..].to_string();
    }
    keep.push_str(&rest);
    keep
}

/// Leading verb word. Mirrors `status_line_verb`: past the first word,
/// only exact correlation tokens are dropped, so prose keeps matching no verb.
pub fn verb(line: &str) -> String {
    let head = match line.split(':').next() {
        Some(h) => h,
        None => line,
    };
    let head = match head.split('[').next() {
        Some(h) => h,
        None => head,
    };
    let trimmed = head.trim_matches(is_space);
    if !trimmed.contains("corr=") {
        return trimmed.to_string();
    }
    let mut words = trimmed.split(is_space).filter(|w| !w.is_empty());
    let first = words.next().unwrap_or("");
    let mut out = first.to_string();
    for w in words {
        if is_corr_token(w) {
            continue;
        }
        out.push(' ');
        out.push_str(w);
    }
    out
}

/// Well-formed epoch from a single `[at=<digits>]` tag before the colon.
/// Mirrors `_fm_status_at_epoch`: digits only, no leading zero on a
/// multi-digit value, at most 12 digits, no second `[at=` in the head.
pub fn at_epoch(line: &str) -> Option<u64> {
    let head = line.split(':').next()?;
    if !line.contains(':') {
        return None;
    }
    let start = head.find("[at=")?;
    let after = &head[start + 4..];
    let end = after.find(']')?;
    let value = &after[..end];
    if after[end + 1..].contains("[at=") {
        return None;
    }
    if value.is_empty() || value.len() > 12 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if value.len() > 1 && value.starts_with('0') {
        return None;
    }
    value.parse().ok()
}

fn slug_ok(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn key_before_colon(unstamped_line: &str) -> bool {
    let head = unstamped_line.split(':').next().unwrap_or(unstamped_line);
    // Bash checks the text before the first colon, or the whole line when
    // there is no colon (`${1%%:*}` keeps the whole string then).
    let target = if unstamped_line.contains(':') {
        head
    } else {
        unstamped_line
    };
    has_key_token(target)
}

fn key_at_note_head(unstamped_line: &str) -> Option<String> {
    let rest = unstamped_line
        .split_once(':')?
        .1
        .trim_start_matches(is_space);
    let inner = rest.strip_prefix("[key=")?;
    let end = inner.find(']')?;
    Some(inner[..end].to_string())
}

/// Decision key for a line. `None` means a stated key was malformed,
/// matching `_fm_decision_key` failing; callers fold such lines as no-ops.
/// An absent key yields `keyless` (bash default `default`).
pub fn decision_key(line: &str, keyless: &str) -> Option<String> {
    let u = unstamped(line);
    let raw = if key_before_colon(&u) {
        let head = if u.contains(':') {
            u.split(':').next().unwrap_or(&u).to_string()
        } else {
            u.clone()
        };
        let i = head.find("[key=")?;
        let after = &head[i + 5..];
        let end = after.find(']')?;
        after[..end].to_string()
    } else {
        match key_at_note_head(&u) {
            Some(k) => k,
            None => return Some(keyless.to_string()),
        }
    };
    if slug_ok(&raw) {
        Some(raw)
    } else {
        None
    }
}

/// Note text after the first colon on the unstamped copy.
/// Mirrors `status_line_note`, including stripping a note-head key token.
pub fn note(line: &str) -> String {
    let u = unstamped(line);
    let Some((_, rest)) = u.split_once(':') else {
        return u;
    };
    let mut n = rest.trim_start_matches(is_space).to_string();
    if !key_before_colon(&u) {
        if let Some(k) = key_at_note_head(&u) {
            if slug_ok(&k) {
                let token = format!("[key={k}]");
                if let Some(stripped) = n.strip_prefix(&token) {
                    n = stripped.trim_start_matches(is_space).to_string();
                }
            }
        }
    }
    n
}

fn transition_allowed(key: &str, note_text: &str, reserved: &[String]) -> bool {
    for prefix in reserved {
        let prefix = prefix.as_str();
        if key.starts_with(prefix) {
            return note_text.starts_with(prefix) && note_text[prefix.len()..].contains(':');
        }
    }
    true
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenDecision {
    pub key: String,
    pub verb: String,
    pub note: String,
}

/// Whole-file open-decisions fold. Mirrors `status_open_decisions` with
/// `_fm_decision_fold_line`: needs-decision/blocked open or replace,
/// resolved/captain-held close, and a ship/scout done/failed clears all.
pub fn open_decisions(lines: &[String], kind: &str) -> Vec<OpenDecision> {
    let resolve = resolve_verb();
    let held = held_verb();
    let reserved = reserved_prefixes();
    let mut open: Vec<OpenDecision> = Vec::new();
    for line in lines {
        let v = verb(line);
        let opens = v == "needs-decision" || v == "blocked";
        let closes = v == resolve || v == held;
        if !opens && !closes && v != "done" && v != "failed" {
            continue;
        }
        let u = unstamped(line);
        if !u.contains(':') && !has_key_token(&u) {
            continue;
        }
        if u.contains(':') && matches!((v.as_str(), kind), ("done" | "failed", "ship" | "scout")) {
            open.clear();
            continue;
        }
        if !opens && !closes {
            continue;
        }
        let Some(key) = decision_key(line, "default") else {
            continue;
        };
        let note_text = note(line);
        if !transition_allowed(&key, &note_text, &reserved) {
            continue;
        }
        open.retain(|d| d.key != key);
        if opens {
            open.push(OpenDecision {
                key,
                verb: v.clone(),
                note: note_text,
            });
        }
    }
    open
}

/// Last recognized status event, skipping blanks and continuation prose.
/// A line counts when its verb is a recognized status verb and the
/// unstamped line carries the colon that ends the declaration head.
/// Bash `last_status_line` also surfaces unrecognized declaration
/// prefixes as events; fmd's readers only need recognized events.
pub fn last_event(lines: &[String]) -> Option<String> {
    let recognized = [
        "working".to_string(),
        "needs-decision".to_string(),
        "blocked".to_string(),
        "done".to_string(),
        "failed".to_string(),
        "note".to_string(),
        paused_verb(),
        resolve_verb(),
        held_verb(),
    ];
    lines
        .iter()
        .rev()
        .find(|l| {
            !l.trim().is_empty() && unstamped(l).contains(':') && recognized.contains(&verb(l))
        })
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(s: &str) -> Vec<String> {
        s.lines().map(str::to_string).collect()
    }

    #[test]
    fn unstamped_strips_readable_time() {
        assert_eq!(unstamped("blocked [at=10:30]: stuck"), "blocked: stuck");
        assert_eq!(unstamped("done [at=123]: ok [at=9]"), "done: ok [at=9]");
    }

    #[test]
    fn epoch_rules() {
        assert_eq!(at_epoch("working [at=1795115339]: go"), Some(1795115339));
        assert_eq!(at_epoch("working [at=0123]: go"), None);
        assert_eq!(at_epoch("working: go"), None);
        assert_eq!(at_epoch("working [at=<epoch>]: go"), None);
    }

    #[test]
    fn key_and_note_positions_agree() {
        let a = "needs-decision [key=api-1] [at=100]: pick one";
        let b = "needs-decision: [key=api-1] pick one";
        assert_eq!(decision_key(a, "default").as_deref(), Some("api-1"));
        assert_eq!(decision_key(b, "default").as_deref(), Some("api-1"));
        assert_eq!(note(a), "pick one");
        assert_eq!(note(b), "pick one");
    }

    #[test]
    fn fold_open_replace_resolve() {
        let open = open_decisions(
            &lines(
                "needs-decision [key=a] [at=1]: first\n\
                 working [at=2]: resumed\n\
                 blocked [key=b] [at=3]: stuck\n\
                 resolved [key=a] [at=4]: answered\n",
            ),
            "ship",
        );
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].key, "b");
        assert_eq!(open[0].verb, "blocked");
    }

    #[test]
    fn fold_terminal_ship_clears_secondmate_does_not() {
        let src = "blocked [key=b] [at=1]: stuck\ndone [at=2]: shipped\n";
        assert!(open_decisions(&lines(src), "ship").is_empty());
        assert_eq!(open_decisions(&lines(src), "secondmate").len(), 1);
    }

    #[test]
    fn fold_reserved_key_needs_own_vocabulary() {
        let src = "blocked [key=pending-reply-x] [at=1]: unrelated prose\n\
                   blocked [key=pending-reply-y] [at=2]: pending-reply-missed: task=t\n";
        let open = open_decisions(&lines(src), "ship");
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].key, "pending-reply-y");
    }

    #[test]
    fn last_event_skips_continuation_prose() {
        let src = "paused [at=1]: waiting on ci\n\
                   S6 captain call still open: an outside agent moved the branch\n";
        assert_eq!(
            last_event(&lines(src)).as_deref(),
            Some("paused [at=1]: waiting on ci")
        );
    }

    #[test]
    fn verb_drops_only_exact_corr_tokens() {
        assert_eq!(verb("resolved corr=x [key=a]: done"), "resolved corr=x");
        assert_eq!(verb("resolved corr [key=a]: done"), "resolved corr");
        assert_eq!(
            verb("resolved corr=0123456789abcdef [key=a]: done"),
            "resolved"
        );
    }

    #[test]
    fn fold_colonless_needs_complete_key_token() {
        assert!(open_decisions(&lines("blocked [key=abc\n"), "ship").is_empty());
        let open = open_decisions(&lines("blocked [key=abc]\n"), "ship");
        assert_eq!(open[0].key, "abc");
    }

    #[test]
    fn fold_keyless_uses_default() {
        let open = open_decisions(&lines("blocked [at=1]: no key\n"), "ship");
        assert_eq!(open[0].key, "default");
    }
}
