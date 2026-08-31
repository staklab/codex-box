use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub email: String,
    pub openai_account_id: String,
    pub plan_type: String,
    pub primary_used_percent: f64,
    pub secondary_used_percent: f64,
    pub primary_reset_at: Option<DateTime<Utc>>,
    pub secondary_reset_at: Option<DateTime<Utc>>,
    pub last_checked: Option<DateTime<Utc>>,
    pub is_active: bool,
    pub is_suspended: bool,
    pub token_expired: bool,
    pub organization_name: Option<String>,
}

impl Account {
    pub fn remote_account_id(&self) -> &str {
        if self.openai_account_id.is_empty() {
            &self.id
        } else {
            &self.openai_account_id
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AccountCredentials {
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    pub client_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageSnapshot {
    pub plan_type: String,
    pub primary_used_percent: f64,
    pub secondary_used_percent: f64,
    pub primary_reset_at: Option<DateTime<Utc>>,
    pub secondary_reset_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub account_id: Option<String>,
    pub codex_home: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CostSummary {
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub estimated_usd: f64,
    pub session_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStatus {
    pub base_url: String,
    pub api_key: String,
    pub account_id: String,
    pub account_email: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PublicConfig {
    #[serde(default = "config_version")]
    pub version: u32,
    #[serde(default)]
    pub accounts: Vec<Account>,
    #[serde(default)]
    pub profiles: Vec<Profile>,
    #[serde(default)]
    pub gateway_enabled: bool,
    #[serde(default)]
    pub start_at_login: bool,
}

fn config_version() -> u32 {
    1
}
