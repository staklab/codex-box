use crate::models::{Account, AccountCredentials};
use crate::oauth;
use serde_json::{json, Value};
use std::path::Path;

const MAX_IMPORT_BYTES: u64 = 16 * 1024 * 1024;
type AccountWithCredentials = (Account, AccountCredentials);
type ImportResult = (Vec<AccountWithCredentials>, Option<String>);

pub fn export_json(
    path: &Path,
    accounts: Vec<(Account, AccountCredentials)>,
) -> anyhow::Result<usize> {
    validate_export_path(path)?;
    let active = accounts
        .iter()
        .find(|(account, _)| account.is_active)
        .map(|(account, _)| account.id.clone());
    let items: Vec<_> = accounts
        .iter()
        .map(|(account, credentials)| {
            json!({
                "platform": "openai",
                "type": "oauth",
                "credentials": {
                    "access_token": credentials.access_token,
                    "refresh_token": credentials.refresh_token,
                    "id_token": credentials.id_token,
                    "client_id": credentials.client_id,
                    "email": account.email,
                    "chatgpt_account_id": account.openai_account_id,
                }
            })
        })
        .collect();
    let document = json!({
        "type": "rhino2api-data",
        "exported_at": chrono::Utc::now(),
        "active_account_id": active,
        "accounts": items,
        "proxies": []
    });
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, serde_json::to_vec_pretty(&document)?)?;
    restrict_permissions(path)?;
    Ok(accounts.len())
}

pub fn import(path: &Path) -> anyhow::Result<ImportResult> {
    let metadata = std::fs::metadata(path)?;
    if !metadata.is_file() || metadata.len() > MAX_IMPORT_BYTES {
        anyhow::bail!("账号文件无效或超过 16 MiB")
    }
    let data = std::fs::read(path)?;
    let text = std::str::from_utf8(&data)?;
    if text.trim_start().starts_with('{') {
        parse_json(text)
    } else {
        parse_csv(text)
    }
}

fn parse_json(text: &str) -> anyhow::Result<ImportResult> {
    let document: Value = serde_json::from_str(text)?;
    if let Some(kind) = document.get("type").and_then(Value::as_str) {
        if !matches!(kind, "rhino2api-data" | "rhino2api-bundle") {
            anyhow::bail!("账号文件类型不受支持")
        }
    }
    let items = document
        .get("accounts")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("账号文件缺少 accounts"))?;
    let mut accounts = Vec::new();
    for item in items {
        if item.get("platform").and_then(Value::as_str) != Some("openai")
            || item.get("type").and_then(Value::as_str) != Some("oauth")
        {
            continue;
        }
        let credentials = credentials_from_value(
            item.get("credentials")
                .ok_or_else(|| anyhow::anyhow!("账号缺少 credentials"))?,
        )?;
        let account = oauth::account_from_credentials(&credentials)?;
        accounts.push((account, credentials));
    }
    ensure_unique(&accounts)?;
    if accounts.is_empty() {
        anyhow::bail!("文件中没有可导入的 OpenAI OAuth 账号")
    }
    let active = document
        .get("active_account_id")
        .and_then(Value::as_str)
        .filter(|id| accounts.iter().any(|(account, _)| account.id == *id))
        .map(str::to_owned);
    Ok((accounts, active))
}

fn parse_csv(text: &str) -> anyhow::Result<ImportResult> {
    let mut reader = csv::ReaderBuilder::new()
        .trim(csv::Trim::All)
        .from_reader(text.as_bytes());
    let headers = reader.headers()?.clone();
    for required in [
        "format_version",
        "access_token",
        "refresh_token",
        "id_token",
        "is_active",
    ] {
        if !headers.iter().any(|header| header == required) {
            anyhow::bail!("CSV 缺少必要列 {required}")
        }
    }
    let position = |name: &str| {
        headers
            .iter()
            .position(|header| header == name)
            .expect("已验证列")
    };
    let mut accounts = Vec::new();
    let mut active = None;
    for row in reader.records() {
        let row = row?;
        if row.get(position("format_version")) != Some("v1") {
            anyhow::bail!("CSV 格式版本不受支持")
        }
        let credentials = AccountCredentials {
            access_token: required_csv(&row, position("access_token"), "access_token")?,
            refresh_token: required_csv(&row, position("refresh_token"), "refresh_token")?,
            id_token: required_csv(&row, position("id_token"), "id_token")?,
            client_id: None,
        };
        let account = oauth::account_from_credentials(&credentials)?;
        let is_active = row.get(position("is_active")).unwrap_or_default();
        if matches!(is_active.to_lowercase().as_str(), "1" | "true" | "yes") {
            if active.is_some() {
                anyhow::bail!("CSV 只能声明一个当前账号")
            }
            active = Some(account.id.clone());
        } else if !matches!(is_active.to_lowercase().as_str(), "" | "0" | "false" | "no") {
            anyhow::bail!("CSV is_active 值无效")
        }
        accounts.push((account, credentials));
    }
    ensure_unique(&accounts)?;
    if accounts.is_empty() {
        anyhow::bail!("CSV 中没有账号")
    }
    Ok((accounts, active))
}

fn credentials_from_value(value: &Value) -> anyhow::Result<AccountCredentials> {
    let required = |key: &str| {
        value
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("账号凭据缺少 {key}"))
    };
    Ok(AccountCredentials {
        access_token: required("access_token")?,
        refresh_token: required("refresh_token")?,
        id_token: required("id_token")?,
        client_id: value
            .get("client_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

fn required_csv(row: &csv::StringRecord, index: usize, name: &str) -> anyhow::Result<String> {
    row.get(index)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("CSV 缺少 {name}"))
}

fn ensure_unique(accounts: &[(Account, AccountCredentials)]) -> anyhow::Result<()> {
    let mut ids = std::collections::HashSet::new();
    if accounts.iter().any(|(account, _)| !ids.insert(&account.id)) {
        anyhow::bail!("账号文件包含重复账号")
    }
    Ok(())
}

fn validate_export_path(path: &Path) -> anyhow::Result<()> {
    if !path.is_absolute()
        || path.extension().and_then(|extension| extension.to_str()) != Some("json")
    {
        anyhow::bail!("导出路径必须是绝对路径且扩展名为 .json")
    }
    Ok(())
}

#[cfg(unix)]
fn restrict_permissions(path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_relative_export_paths() {
        assert!(validate_export_path(Path::new("accounts.json")).is_err());
    }

    #[test]
    fn rejects_unknown_json_bundle_type_without_exposing_secrets() {
        let result = parse_json(r#"{"type":"unknown","accounts":[]}"#)
            .unwrap_err()
            .to_string();
        assert!(result.contains("类型"));
        assert!(!result.contains("token"));
    }
}
