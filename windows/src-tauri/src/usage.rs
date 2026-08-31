use crate::models::{Account, AccountCredentials, UsageSnapshot};
use chrono::{TimeZone, Utc};
use serde_json::Value;

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";

pub async fn fetch(
    account: &Account,
    credentials: &AccountCredentials,
) -> anyhow::Result<UsageSnapshot> {
    let response = reqwest::Client::new().get(USAGE_URL)
        .bearer_auth(&credentials.access_token)
        .header("chatgpt-account-id", account.remote_account_id())
        .header("accept", "*/*").header("oai-language", "zh-CN")
        .header("referer", "https://chatgpt.com/codex/settings/usage")
        .header("user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36")
        .timeout(std::time::Duration::from_secs(20)).send().await?;
    let status = response.status();
    if status.as_u16() == 401 {
        anyhow::bail!("TOKEN_EXPIRED");
    }
    if matches!(status.as_u16(), 402 | 403) {
        anyhow::bail!("当前账号无法访问用量端点（HTTP {}）", status.as_u16());
    }
    if !status.is_success() {
        anyhow::bail!("用量请求失败（HTTP {}）", status.as_u16());
    }
    parse(&response.json::<Value>().await?)
}

pub fn parse(value: &Value) -> anyhow::Result<UsageSnapshot> {
    let rate_limit = value
        .get("rate_limit")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow::anyhow!("用量响应缺少 rate_limit"))?;
    let mut windows: Vec<(i64, f64, Option<chrono::DateTime<Utc>>)> =
        ["primary_window", "secondary_window"]
            .into_iter()
            .filter_map(|key| {
                let window = rate_limit.get(key)?.as_object()?;
                let used = window
                    .get("used_percent")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0);
                let seconds = window
                    .get("limit_window_seconds")
                    .and_then(Value::as_i64)
                    .unwrap_or(i64::MAX);
                let reset = window
                    .get("reset_at")
                    .and_then(Value::as_i64)
                    .and_then(|stamp| Utc.timestamp_opt(stamp, 0).single());
                (used > 0.0 || seconds != i64::MAX || reset.is_some())
                    .then_some((seconds, used, reset))
            })
            .collect();
    windows.sort_by_key(|window| window.0);
    windows.dedup_by(|next, current| {
        if next.0 == current.0 {
            if next.1 > current.1 {
                *current = *next;
            }
            true
        } else {
            false
        }
    });
    Ok(UsageSnapshot {
        plan_type: value
            .get("plan_type")
            .and_then(Value::as_str)
            .unwrap_or("free")
            .to_owned(),
        primary_used_percent: windows.first().map_or(0.0, |window| window.1),
        secondary_used_percent: windows.get(1).map_or(0.0, |window| window.1),
        primary_reset_at: windows.first().and_then(|window| window.2),
        secondary_reset_at: windows.get(1).and_then(|window| window.2),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorts_windows_by_duration() {
        let value = serde_json::json!({"plan_type":"plus","rate_limit":{
            "primary_window":{"used_percent":20.0,"limit_window_seconds":604800,"reset_at":2000000000},
            "secondary_window":{"used_percent":10.0,"limit_window_seconds":18000,"reset_at":1900000000}
        }});
        let parsed = parse(&value).unwrap();
        assert_eq!(parsed.plan_type, "plus");
        assert_eq!(parsed.primary_used_percent, 10.0);
        assert_eq!(parsed.secondary_used_percent, 20.0);
    }

    #[test]
    fn rejects_missing_rate_limit() {
        assert!(parse(&serde_json::json!({})).is_err());
    }
}
