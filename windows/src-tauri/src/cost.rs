use crate::models::CostSummary;
use serde_json::Value;
use std::collections::HashSet;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

#[derive(Default, Clone, Copy)]
struct Tokens {
    input: u64,
    cached: u64,
    output: u64,
}

pub fn summarize(root: &Path) -> anyhow::Result<CostSummary> {
    if !root.exists() {
        return Ok(CostSummary::default());
    }
    let mut summary = CostSummary::default();
    let mut sessions = HashSet::new();
    for entry in walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_file()
            || entry.path().extension().and_then(|ext| ext.to_str()) != Some("jsonl")
        {
            continue;
        }
        let (tokens, model, found) = summarize_session(entry.path())?;
        if !found {
            continue;
        }
        sessions.insert(entry.path().to_path_buf());
        summary.input_tokens += tokens.input;
        summary.cached_input_tokens += tokens.cached;
        summary.output_tokens += tokens.output;
        summary.estimated_usd += estimate(&model, tokens);
    }
    summary.session_count = sessions.len() as u64;
    Ok(summary)
}

fn summarize_session(path: &Path) -> anyhow::Result<(Tokens, String, bool)> {
    let mut latest = Tokens::default();
    let mut model = String::new();
    let mut found = false;
    for line in BufReader::new(File::open(path)?)
        .lines()
        .map_while(Result::ok)
    {
        if !line.contains("token_count") && !line.contains("session_meta") {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let payload = value.get("payload").unwrap_or(&value);
        if let Some(candidate) = payload
            .get("model")
            .or_else(|| payload.get("model_name"))
            .and_then(Value::as_str)
        {
            model = candidate.to_owned();
        }
        let info = payload.get("info").unwrap_or(payload);
        let Some(total) = info
            .get("total_token_usage")
            .or_else(|| payload.get("total_token_usage"))
        else {
            continue;
        };
        latest = Tokens {
            input: total
                .get("input_tokens")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            cached: total
                .get("cached_input_tokens")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            output: total
                .get("output_tokens")
                .and_then(Value::as_u64)
                .unwrap_or(0),
        };
        found = true;
    }
    Ok((latest, normalize_model(&model), found))
}

fn normalize_model(model: &str) -> String {
    let model = model.strip_prefix("openai/").unwrap_or(model);
    if model == "gpt-5.6" {
        "gpt-5.6-sol".into()
    } else {
        model.into()
    }
}

fn estimate(model: &str, tokens: Tokens) -> f64 {
    let (input_rate, cached_rate, output_rate) = match model {
        "gpt-5.6-sol" | "gpt-5.5" => (5e-6, 5e-7, 3e-5),
        "gpt-5.6-terra" | "gpt-5.4" => (2.5e-6, 2.5e-7, 1.5e-5),
        "gpt-5.6-luna" => (1e-6, 1e-7, 6e-6),
        "gpt-5.2" | "gpt-5.2-codex" | "gpt-5.3-codex" => (1.75e-6, 1.75e-7, 1.4e-5),
        "gpt-5" | "gpt-5-codex" | "gpt-5.1" | "gpt-5.1-codex" => (1.25e-6, 1.25e-7, 1e-5),
        _ => (0.0, 0.0, 0.0),
    };
    let cached = tokens.cached.min(tokens.input);
    ((tokens.input - cached) as f64 * input_rate)
        + (cached as f64 * cached_rate)
        + (tokens.output as f64 * output_rate)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn uses_latest_cumulative_usage_per_session() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.jsonl");
        let mut file = File::create(&path).unwrap();
        writeln!(file, "{}", serde_json::json!({"payload":{"type":"token_count","model":"gpt-5.6-luna","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}})).unwrap();
        writeln!(file, "{}", serde_json::json!({"payload":{"type":"token_count","model":"gpt-5.6-luna","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":50,"output_tokens":20}}}})).unwrap();
        let summary = summarize(dir.path()).unwrap();
        assert_eq!(summary.input_tokens, 200);
        assert_eq!(summary.cached_input_tokens, 50);
        assert_eq!(summary.session_count, 1);
        assert!(summary.estimated_usd > 0.0);
    }
}
