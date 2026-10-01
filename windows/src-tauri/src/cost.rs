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
    cache_write: u64,
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
        let (tokens, cost, found) = summarize_session(entry.path())?;
        if !found {
            continue;
        }
        sessions.insert(entry.path().to_path_buf());
        summary.input_tokens += tokens.input;
        summary.cached_input_tokens += tokens.cached;
        summary.output_tokens += tokens.output;
        summary.estimated_usd += cost;
    }
    summary.session_count = sessions.len() as u64;
    Ok(summary)
}

fn summarize_session(path: &Path) -> anyhow::Result<(Tokens, f64, bool)> {
    let mut latest = Tokens::default();
    let mut model = String::new();
    let mut tier = String::new();
    let mut found = false;
    let mut cost = 0.0;
    for line in BufReader::new(File::open(path)?).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
        let payload = value.get("payload").unwrap_or(&value);
        let info = payload.get("info").unwrap_or(payload);
        let settings = payload.get("thread_settings").or_else(|| payload.get("threadSettings")).unwrap_or(payload);
        if let Some(candidate) = payload.get("model").or_else(|| payload.get("model_name"))
            .or_else(|| settings.get("model")).or_else(|| settings.get("model_name"))
            .or_else(|| info.get("model")).or_else(|| info.get("model_name")).and_then(Value::as_str) {
            model = normalize_model(candidate);
        }
        if let Some(value) = settings.get("service_tier").or_else(|| settings.get("serviceTier"))
            .or_else(|| payload.get("service_tier")).or_else(|| payload.get("serviceTier"))
            .or_else(|| info.get("service_tier")).or_else(|| info.get("serviceTier")).and_then(Value::as_str) {
            tier = value.into();
        }
        let Some(total) = info.get("total_token_usage").or_else(|| payload.get("total_token_usage")) else { continue };
        let next = parse_tokens(total);
        let delta = Tokens { input: next.input.saturating_sub(latest.input), cached: next.cached.saturating_sub(latest.cached),
            output: next.output.saturating_sub(latest.output), cache_write: next.cache_write.saturating_sub(latest.cache_write) };
        // 按请求计算长上下文加价，不能把整段会话的累计用量当单次请求。
        if delta.input > 0 || delta.output > 0 {
            cost += estimate(&model, delta, &tier);
        }
        latest = next;
        found = true;
    }
    Ok((latest, cost, found))
}

fn parse_tokens(value: &Value) -> Tokens {
    Tokens { input: value["input_tokens"].as_u64().unwrap_or(0), cached: value["cached_input_tokens"].as_u64().unwrap_or(0),
        output: value["output_tokens"].as_u64().unwrap_or(0),
        cache_write: value["cache_write_tokens"].as_u64().or_else(|| value["cache_creation_input_tokens"].as_u64()).unwrap_or(0) }
}

fn normalize_model(model: &str) -> String {
    let model = model.trim();
    let model = model.strip_prefix("openai/").unwrap_or(model);
    for base in ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"] {
        if let Some(date) = model.strip_prefix(base).and_then(|suffix| suffix.strip_prefix('-')) {
            let bytes = date.as_bytes();
            if bytes.len() == 10 && bytes[4] == b'-' && bytes[7] == b'-'
                && bytes.iter().enumerate().all(|(i, ch)| i == 4 || i == 7 || ch.is_ascii_digit()) {
                return base.into();
            }
        }
    }
    if model == "gpt-5.6" {
        "gpt-5.6-sol".into()
    } else {
        model.into()
    }
}

fn estimate(model: &str, tokens: Tokens, tier: &str) -> f64 {
    let normalized = normalize_model(model);
    let model = normalized.as_str();
    // 2026-10-01 官方 API 定价；与 macOS 共用相同的 Fast、缓存写入和长上下文规则。
    let gpt6_rates = match model {
        "gpt-6-astra" => Some((10e-6, 1e-6, 50e-6)),
        "gpt-6.1-sol" => Some((2e-6, 0.1e-6, 10e-6)),
        "gpt-6-sol" => Some((2e-6, 0.2e-6, 10e-6)),
        "gpt-6-luna" => Some((0.1e-6, 0.01e-6, 0.5e-6)),
        _ => None,
    };
    if let Some((input_rate, cached_rate, output_rate)) = gpt6_rates {
        let cached = tokens.cached.min(tokens.input);
        let write = tokens.cache_write.min(tokens.input - cached);
        let long = tokens.input > 272000;
        let input_factor = if long { 2.0 } else { 1.0 };
        let output_factor = if long { 1.5 } else { 1.0 };
        let speed = match tier.trim().to_ascii_lowercase().as_str() { "fast" | "priority" => 2.0, "flex" | "batch" => 0.5, _ => 1.0 };
        return ((tokens.input - cached - write) as f64 * input_rate * input_factor
            + cached as f64 * cached_rate * input_factor + write as f64 * input_rate * 1.25 * input_factor
            + tokens.output as f64 * output_rate * output_factor) * speed;
    }
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
    fn astra_long_context_and_speed_rates() {
        for (input, base) in [(272000, 3.065), (272001, 5.88002)] {
            let tokens = Tokens { input, cached: 20000, output: 10000, cache_write: 10000 };
            assert!((estimate("gpt-6-astra", tokens, "default") - base).abs() < 1e-8);
            assert!((estimate("gpt-6-astra", tokens, "fast") - base * 2.0).abs() < 1e-8);
            assert!((estimate("gpt-6-astra", tokens, "flex") - base * 0.5).abs() < 1e-8);
        }
    }

    #[test]
    fn gpt6_sol_luna_request_threshold_and_speed_rates() {
        for (model, short, long) in [("gpt-6.1-sol", 0.611, 1.172004), ("gpt-6-sol", 0.613, 1.176004), ("gpt-6-luna", 0.03065, 0.0588002)] {
            for (input, base) in [(272000, short), (272001, long)] {
                let tokens = Tokens { input, cached: 20000, output: 10000, cache_write: 10000 };
                for (tier, multiplier) in [("default", 1.0), ("standard", 1.0), ("fast", 2.0), ("priority", 2.0), ("flex", 0.5), ("batch", 0.5), ("unknown", 1.0)] {
                    assert!((estimate(model, tokens, tier) - base * multiplier).abs() < 1e-12, "{model}/{tier}/{input}");
                    assert!((estimate(&format!(" openai/{model}-2026-10-01 "), tokens, tier) - base * multiplier).abs() < 1e-12);
                }
            }
        }
        assert_eq!(estimate("gpt-6.1-sol-preview", Tokens { input: 100, ..Default::default() }, "default"), 0.0);
    }

    #[test]
    fn gpt6_cache_writes_and_reads_are_not_double_counted() {
        let tokens = Tokens { input: 100, cached: 200, output: 0, cache_write: 999 };
        for (model, expected) in [("gpt-6.1-sol", 0.00001), ("gpt-6-sol", 0.00002), ("gpt-6-luna", 0.000001)] {
            assert!((estimate(model, tokens, "default") - expected).abs() < 1e-12);
        }
    }

    #[test]
    fn gpt6_session_records_each_request_model_and_tier() {
        let dir = tempfile::tempdir().unwrap();
        let mut file = File::create(dir.path().join("session.jsonl")).unwrap();
        for value in [
            serde_json::json!({"payload":{"type":"turn_context","model":"gpt-6.1-sol","service_tier":"default"}}),
            serde_json::json!({"payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"fast"}}}),
            serde_json::json!({"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_tokens":10,"output_tokens":10}}}}),
            serde_json::json!({"payload":{"type":"turn_context","model":"gpt-6-sol","service_tier":"default"}}),
            serde_json::json!({"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":40,"cache_write_tokens":20,"output_tokens":20}}}}),
            serde_json::json!({"payload":{"type":"token_count","info":{"model":"gpt-6-luna","service_tier":"fast","total_token_usage":{"input_tokens":300,"cached_input_tokens":60,"cache_creation_input_tokens":30,"output_tokens":30}}}}),
        ] {
            writeln!(file, "{value}").unwrap();
        }
        let summary = summarize(dir.path()).unwrap();
        assert_eq!(summary.input_tokens, 300);
        assert_eq!(summary.cached_input_tokens, 60);
        assert_eq!(summary.output_tokens, 30);
        assert!((summary.estimated_usd - 0.0008299).abs() < 1e-12);
    }

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
