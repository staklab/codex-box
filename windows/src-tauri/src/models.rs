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
    pub route_model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAccount {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Provider {
    pub id: String,
    pub label: String,
    pub kind: String,
    pub base_url: String,
    pub model: String,
    pub accounts: Vec<ProviderAccount>,
    pub active_account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThemeSource {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub enabled: bool,
    pub format: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThemeColors {
    pub background: Option<String>,
    pub panel: Option<String>,
    pub panel_alt: Option<String>,
    pub accent: Option<String>,
    pub accent_alt: Option<String>,
    pub secondary: Option<String>,
    pub highlight: Option<String>,
    pub text: Option<String>,
    pub muted: Option<String>,
    pub line: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThemeListing {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub license: Option<String>,
    pub tags: Vec<String>,
    pub theme: String,
    pub preview: Option<String>,
    pub source_base_url: String,
    pub source_name: String,
    pub is_pack: bool,
    pub declared_sha256: Option<String>,
    pub inline_colors: Option<ThemeColors>,
    pub inline_appearance: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InstalledTheme {
    pub id: String,
    pub name: String,
    pub version: String,
    pub installed_at: DateTime<Utc>,
    pub theme_sha256: String,
    pub image_sha256: Option<String>,
    pub has_image: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThemeState {
    pub installed: Vec<InstalledTheme>,
    pub applied_theme_id: Option<String>,
    pub auto_reapply: bool,
    pub codex_executable: Option<String>,
    pub debug_port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThemePage {
    pub items: Vec<ThemeListing>,
    pub total: usize,
    pub offset: usize,
    pub limit: usize,
    pub issues: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecord {
    pub session_id: String,
    pub model_id: String,
    pub started_at: Option<DateTime<Utc>>,
    pub last_activity_at: Option<DateTime<Utc>>,
    pub archived: bool,
    pub total_tokens: u64,
    pub file_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelRecord {
    pub model_id: String,
    pub session_count: usize,
    pub last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RecordsSnapshot {
    pub sessions: Vec<SessionRecord>,
    pub models: Vec<ModelRecord>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPreset {
    pub model: String,
    pub reasoning_effort: String,
    pub service_tier: String,
    pub context_window: u64,
}

impl Default for ThreadPreset {
    fn default() -> Self {
        Self {
            model: "gpt-5.6-sol".into(),
            reasoning_effort: "medium".into(),
            service_tier: "flex".into(),
            context_window: 272_000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DesktopStatus {
    pub connected: bool,
    pub target: String,
    pub conversation_id: Option<String>,
    pub preset: ThreadPreset,
    pub codex_executable: Option<String>,
    pub debug_port: Option<u16>,
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
    #[serde(default)]
    pub providers: Vec<Provider>,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub theme_sources: Vec<ThemeSource>,
    #[serde(default)]
    pub theme_state: ThemeState,
    #[serde(default)]
    pub thread_preset: ThreadPreset,
    #[serde(default)]
    pub auto_route_enabled: bool,
    #[serde(default = "default_auto_route_threshold")]
    pub auto_route_threshold: f64,
}

fn config_version() -> u32 {
    2
}

fn default_auto_route_threshold() -> f64 {
    90.0
}
