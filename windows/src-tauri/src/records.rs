use crate::models::{ModelRecord, RecordsSnapshot, SessionRecord};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::cmp::Reverse;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

const MAX_SESSION_FILES: usize = 2_000;
const MAX_WARNINGS: usize = 100;

pub fn snapshot(root: &Path) -> anyhow::Result<RecordsSnapshot> {
    if !root.exists() {
        return Ok(RecordsSnapshot::default());
    }
    let mut paths: Vec<(PathBuf, std::time::SystemTime)> = walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry.file_type().is_file()
                && entry
                    .path()
                    .extension()
                    .and_then(|extension| extension.to_str())
                    == Some("jsonl")
        })
        .filter_map(|entry| {
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((entry.into_path(), modified))
        })
        .collect();
    paths.sort_by_key(|item| Reverse(item.1));
    paths.truncate(MAX_SESSION_FILES);

    let mut sessions = Vec::new();
    let mut warnings = Vec::new();
    for (path, _) in paths {
        match parse_session(&path) {
            Ok(Some(session)) => sessions.push(session),
            Ok(None) => {}
            Err(error) if warnings.len() < MAX_WARNINGS => {
                warnings.push(format!("{}：{error}", path.display()));
            }
            Err(_) => {}
        }
    }
    sessions.sort_by(|left, right| {
        right
            .last_activity_at
            .cmp(&left.last_activity_at)
            .then_with(|| left.session_id.cmp(&right.session_id))
    });

    let mut grouped: HashMap<String, (usize, Option<DateTime<Utc>>)> = HashMap::new();
    for session in &sessions {
        let entry = grouped.entry(session.model_id.clone()).or_default();
        entry.0 += 1;
        entry.1 = entry.1.max(session.last_activity_at);
    }
    let mut models: Vec<_> = grouped
        .into_iter()
        .map(|(model_id, (session_count, last_seen_at))| ModelRecord {
            model_id,
            session_count,
            last_seen_at,
        })
        .collect();
    models.sort_by(|left, right| {
        right
            .last_seen_at
            .cmp(&left.last_seen_at)
            .then_with(|| right.session_count.cmp(&left.session_count))
            .then_with(|| left.model_id.cmp(&right.model_id))
    });
    Ok(RecordsSnapshot {
        sessions,
        models,
        warnings,
    })
}

fn parse_session(path: &Path) -> anyhow::Result<Option<SessionRecord>> {
    let file = File::open(path)?;
    let mut session_id = path
        .file_stem()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut model = "unknown".to_owned();
    let mut started = None;
    let mut last_activity = None;
    let mut total_tokens = 0;
    let mut archived = path.to_string_lossy().contains("archived");
    let mut saw_record = false;
    for line in BufReader::new(file).lines() {
        let line = line?;
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        saw_record = true;
        let payload = value.get("payload").unwrap_or(&value);
        if let Some(value) = payload
            .get("id")
            .or_else(|| payload.get("session_id"))
            .and_then(Value::as_str)
        {
            session_id = value.to_owned();
        }
        if let Some(value) = payload
            .get("model")
            .or_else(|| payload.get("model_name"))
            .and_then(Value::as_str)
        {
            model = value.strip_prefix("openai/").unwrap_or(value).to_owned();
        }
        if let Some(timestamp) = value
            .get("timestamp")
            .or_else(|| payload.get("timestamp"))
            .and_then(Value::as_str)
            .and_then(parse_time)
        {
            started = started.or(Some(timestamp));
            last_activity = Some(last_activity.max(Some(timestamp)).unwrap_or(timestamp));
        }
        let info = payload.get("info").unwrap_or(payload);
        if let Some(usage) = info
            .get("total_token_usage")
            .or_else(|| payload.get("total_token_usage"))
        {
            total_tokens = usage
                .get("total_tokens")
                .and_then(Value::as_u64)
                .unwrap_or_else(|| {
                    usage
                        .get("input_tokens")
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                        + usage
                            .get("output_tokens")
                            .and_then(Value::as_u64)
                            .unwrap_or(0)
                });
        }
        archived |= payload
            .get("archived")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    }
    if !saw_record {
        return Ok(None);
    }
    Ok(Some(SessionRecord {
        session_id,
        model_id: model,
        started_at: started,
        last_activity_at: last_activity,
        archived,
        total_tokens,
        file_name: path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default(),
    }))
}

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn creates_detailed_session_and_model_records() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.jsonl");
        let mut file = File::create(path).unwrap();
        writeln!(file, "{}", serde_json::json!({"timestamp":"2026-01-01T00:00:00Z","payload":{"id":"thread-1","model":"openai/gpt-5.6-sol"}})).unwrap();
        writeln!(file, "{}", serde_json::json!({"timestamp":"2026-01-01T00:01:00Z","payload":{"info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}}}})).unwrap();
        let snapshot = snapshot(directory.path()).unwrap();
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.sessions[0].total_tokens, 15);
        assert_eq!(snapshot.models[0].model_id, "gpt-5.6-sol");
    }
}
