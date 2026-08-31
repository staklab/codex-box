use crate::models::{
    Account, AccountCredentials, InstalledTheme, Provider, ProviderAccount, PublicConfig,
    ThemeSource, ThemeState, ThreadPreset,
};
use crate::paths;
use std::fs;
use std::path::{Path, PathBuf};

const KEYRING_SERVICE: &str = "com.codexbox.windows.oauth";
const PROVIDER_KEYRING_SERVICE: &str = "com.codexbox.windows.provider";

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("账号不存在: {0}")]
    AccountNotFound(String),
    #[error("凭据存储失败: {0}")]
    Credential(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

pub struct Store {
    path: PathBuf,
    config: PublicConfig,
}

pub struct ProviderDraft {
    pub id: String,
    pub label: String,
    pub kind: String,
    pub base_url: String,
    pub model: String,
    pub account_label: String,
}

impl Store {
    pub fn open_default() -> Result<Self, StoreError> {
        paths::ensure_directories()?;
        Self::open(paths::config_path()?)
    }

    pub fn open(path: PathBuf) -> Result<Self, StoreError> {
        let mut config: PublicConfig = if path.exists() {
            serde_json::from_slice(&fs::read(&path)?)?
        } else {
            PublicConfig {
                version: 2,
                ..Default::default()
            }
        };
        config.version = 2;
        if config.theme_sources.is_empty() {
            config.theme_sources = crate::themes::built_in_sources();
        }
        Ok(Self { path, config })
    }

    pub fn config(&self) -> &PublicConfig {
        &self.config
    }

    pub fn accounts(&self) -> Vec<Account> {
        self.config.accounts.clone()
    }

    pub fn account(&self, id: &str) -> Result<Account, StoreError> {
        self.config
            .accounts
            .iter()
            .find(|account| account.id == id)
            .cloned()
            .ok_or_else(|| StoreError::AccountNotFound(id.to_owned()))
    }

    pub fn upsert_account(
        &mut self,
        mut account: Account,
        credentials: Option<&AccountCredentials>,
    ) -> Result<(), StoreError> {
        if let Some(credentials) = credentials {
            self.save_credentials(&account.id, credentials)?;
        }
        if account.is_active {
            for existing in &mut self.config.accounts {
                existing.is_active = false;
            }
        }
        if let Some(index) = self
            .config
            .accounts
            .iter()
            .position(|existing| existing.id == account.id)
        {
            if !account.is_active {
                account.is_active = self.config.accounts[index].is_active;
            }
            self.config.accounts[index] = account;
        } else {
            if self.config.accounts.is_empty() {
                account.is_active = true;
            }
            self.config.accounts.push(account);
        }
        self.save()
    }

    pub fn set_active(&mut self, id: &str) -> Result<(), StoreError> {
        if !self.config.accounts.iter().any(|account| account.id == id) {
            return Err(StoreError::AccountNotFound(id.to_owned()));
        }
        for account in &mut self.config.accounts {
            account.is_active = account.id == id;
        }
        self.save()
    }

    pub fn remove_account(&mut self, id: &str) -> Result<(), StoreError> {
        let was_active = self.account(id)?.is_active;
        self.config.accounts.retain(|account| account.id != id);
        if was_active {
            if let Some(first) = self.config.accounts.first_mut() {
                first.is_active = true;
            }
        }
        self.save()?;
        self.delete_credentials(id)
    }

    pub fn add_profile(&mut self, profile: crate::models::Profile) -> Result<(), StoreError> {
        self.config.profiles.push(profile);
        self.save()
    }

    pub fn remove_profile(&mut self, id: &str) -> Result<(), StoreError> {
        self.config.profiles.retain(|profile| profile.id != id);
        self.save()
    }

    pub fn set_start_at_login(&mut self, enabled: bool) -> Result<(), StoreError> {
        self.config.start_at_login = enabled;
        self.save()
    }

    pub fn upsert_provider(
        &mut self,
        draft: ProviderDraft,
        api_key: &str,
    ) -> Result<Provider, StoreError> {
        let ProviderDraft {
            id,
            label,
            kind,
            base_url,
            model,
            account_label,
        } = draft;
        let account_id = uuid::Uuid::new_v4().to_string();
        let account = ProviderAccount {
            id: account_id.clone(),
            label: account_label,
        };
        self.save_provider_key(&id, &account_id, api_key)?;
        let provider = Provider {
            id: id.clone(),
            label,
            kind,
            base_url,
            model,
            accounts: vec![account],
            active_account_id: Some(account_id),
        };
        self.config.providers.retain(|item| item.id != id);
        self.config.providers.push(provider.clone());
        if self.config.active_provider_id.is_none() {
            self.config.active_provider_id = Some(id);
        }
        self.save()?;
        Ok(provider)
    }

    pub fn remove_provider(&mut self, id: &str) -> Result<(), StoreError> {
        if let Some(provider) = self.config.providers.iter().find(|item| item.id == id) {
            for account in &provider.accounts {
                let _ = self.delete_provider_key(id, &account.id);
            }
        }
        self.config.providers.retain(|item| item.id != id);
        if self.config.active_provider_id.as_deref() == Some(id) {
            self.config.active_provider_id =
                self.config.providers.first().map(|item| item.id.clone());
        }
        self.save()
    }

    pub fn add_provider_account(
        &mut self,
        provider_id: &str,
        label: String,
        api_key: &str,
    ) -> Result<Provider, StoreError> {
        let account_id = uuid::Uuid::new_v4().to_string();
        self.save_provider_key(provider_id, &account_id, api_key)?;
        let provider = self
            .config
            .providers
            .iter_mut()
            .find(|provider| provider.id == provider_id)
            .ok_or_else(|| StoreError::Other(anyhow::anyhow!("Provider 不存在")))?;
        provider.accounts.push(ProviderAccount {
            id: account_id.clone(),
            label,
        });
        provider.active_account_id = Some(account_id);
        let result = provider.clone();
        self.save()?;
        Ok(result)
    }

    pub fn remove_provider_account(
        &mut self,
        provider_id: &str,
        account_id: &str,
    ) -> Result<Provider, StoreError> {
        self.delete_provider_key(provider_id, account_id)?;
        let provider = self
            .config
            .providers
            .iter_mut()
            .find(|provider| provider.id == provider_id)
            .ok_or_else(|| StoreError::Other(anyhow::anyhow!("Provider 不存在")))?;
        provider.accounts.retain(|account| account.id != account_id);
        if provider.active_account_id.as_deref() == Some(account_id) {
            provider.active_account_id =
                provider.accounts.first().map(|account| account.id.clone());
        }
        let result = provider.clone();
        self.save()?;
        Ok(result)
    }

    pub fn activate_provider_account(
        &mut self,
        provider_id: &str,
        account_id: &str,
    ) -> Result<(), StoreError> {
        let provider = self
            .config
            .providers
            .iter_mut()
            .find(|provider| provider.id == provider_id)
            .ok_or_else(|| StoreError::Other(anyhow::anyhow!("Provider 不存在")))?;
        if !provider
            .accounts
            .iter()
            .any(|account| account.id == account_id)
        {
            return Err(StoreError::Other(anyhow::anyhow!("Provider 账号不存在")));
        }
        provider.active_account_id = Some(account_id.to_owned());
        self.save()
    }

    pub fn activate_provider(&mut self, id: Option<String>) -> Result<(), StoreError> {
        if let Some(id) = id.as_deref() {
            if !self
                .config
                .providers
                .iter()
                .any(|provider| provider.id == id)
            {
                return Err(StoreError::Other(anyhow::anyhow!("Provider 不存在")));
            }
        }
        self.config.active_provider_id = id;
        self.save()
    }

    pub fn provider_key(&self, provider_id: &str, account_id: &str) -> Result<String, StoreError> {
        let entry = keyring::Entry::new(
            PROVIDER_KEYRING_SERVICE,
            &format!("{provider_id}:{account_id}"),
        )
        .map_err(|error| StoreError::Credential(error.to_string()))?;
        entry
            .get_password()
            .map_err(|error| StoreError::Credential(error.to_string()))
    }

    pub fn set_theme_sources(&mut self, sources: Vec<ThemeSource>) -> Result<(), StoreError> {
        self.config.theme_sources = sources;
        self.save()
    }

    pub fn install_theme(&mut self, theme: InstalledTheme) -> Result<(), StoreError> {
        self.config
            .theme_state
            .installed
            .retain(|item| item.id != theme.id);
        self.config.theme_state.installed.push(theme);
        self.save()
    }

    pub fn remove_theme(&mut self, id: &str) -> Result<(), StoreError> {
        self.config
            .theme_state
            .installed
            .retain(|item| item.id != id);
        if self.config.theme_state.applied_theme_id.as_deref() == Some(id) {
            self.config.theme_state.applied_theme_id = None;
        }
        self.save()
    }

    pub fn set_applied_theme(&mut self, id: Option<String>) -> Result<(), StoreError> {
        self.config.theme_state.applied_theme_id = id;
        self.save()
    }

    pub fn set_theme_runtime(
        &mut self,
        codex_executable: Option<String>,
        debug_port: Option<u16>,
    ) -> Result<(), StoreError> {
        self.config.theme_state.codex_executable = codex_executable;
        self.config.theme_state.debug_port = debug_port;
        self.save()
    }

    pub fn set_auto_reapply(&mut self, enabled: bool) -> Result<(), StoreError> {
        self.config.theme_state.auto_reapply = enabled;
        self.save()
    }

    pub fn set_thread_preset(&mut self, preset: ThreadPreset) -> Result<(), StoreError> {
        self.config.thread_preset = preset;
        self.save()
    }

    pub fn set_auto_route(&mut self, enabled: bool, threshold: f64) -> Result<(), StoreError> {
        self.config.auto_route_enabled = enabled;
        self.config.auto_route_threshold = threshold.clamp(50.0, 100.0);
        self.save()
    }

    pub fn auto_route_if_needed(&mut self) -> Result<Option<String>, StoreError> {
        if !self.config.auto_route_enabled {
            return Ok(None);
        }
        let threshold = self.config.auto_route_threshold;
        let active_needs_switch = self
            .config
            .accounts
            .iter()
            .find(|account| account.is_active)
            .is_some_and(|account| {
                account.token_expired
                    || account.is_suspended
                    || account.primary_used_percent >= threshold
            });
        if !active_needs_switch {
            return Ok(None);
        }
        let candidate = self
            .config
            .accounts
            .iter()
            .filter(|account| {
                !account.token_expired
                    && !account.is_suspended
                    && account.primary_used_percent < threshold
            })
            .min_by(|left, right| {
                left.primary_used_percent
                    .total_cmp(&right.primary_used_percent)
            })
            .map(|account| account.id.clone());
        if let Some(id) = candidate {
            for account in &mut self.config.accounts {
                account.is_active = account.id == id;
            }
            self.save()?;
            Ok(Some(id))
        } else {
            Ok(None)
        }
    }

    pub fn theme_state(&self) -> ThemeState {
        self.config.theme_state.clone()
    }

    pub fn credentials(&self, id: &str) -> Result<AccountCredentials, StoreError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, id)
            .map_err(|error| StoreError::Credential(error.to_string()))?;
        let encoded = entry
            .get_password()
            .map_err(|error| StoreError::Credential(error.to_string()))?;
        serde_json::from_str(&encoded).map_err(StoreError::from)
    }

    fn save_credentials(
        &self,
        id: &str,
        credentials: &AccountCredentials,
    ) -> Result<(), StoreError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, id)
            .map_err(|error| StoreError::Credential(error.to_string()))?;
        let encoded = serde_json::to_string(credentials)?;
        entry
            .set_password(&encoded)
            .map_err(|error| StoreError::Credential(error.to_string()))
    }

    fn delete_credentials(&self, id: &str) -> Result<(), StoreError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, id)
            .map_err(|error| StoreError::Credential(error.to_string()))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(StoreError::Credential(error.to_string())),
        }
    }

    fn save_provider_key(
        &self,
        provider_id: &str,
        account_id: &str,
        api_key: &str,
    ) -> Result<(), StoreError> {
        let entry = keyring::Entry::new(
            PROVIDER_KEYRING_SERVICE,
            &format!("{provider_id}:{account_id}"),
        )
        .map_err(|error| StoreError::Credential(error.to_string()))?;
        entry
            .set_password(api_key)
            .map_err(|error| StoreError::Credential(error.to_string()))
    }

    fn delete_provider_key(&self, provider_id: &str, account_id: &str) -> Result<(), StoreError> {
        let entry = keyring::Entry::new(
            PROVIDER_KEYRING_SERVICE,
            &format!("{provider_id}:{account_id}"),
        )
        .map_err(|error| StoreError::Credential(error.to_string()))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(StoreError::Credential(error.to_string())),
        }
    }

    pub fn save(&self) -> Result<(), StoreError> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("配置路径没有父目录"))?;
        fs::create_dir_all(parent)?;
        let bytes = serde_json::to_vec_pretty(&self.config)?;
        atomic_replace(&self.path, &bytes)?;
        Ok(())
    }
}

fn atomic_replace(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let temp = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        uuid::Uuid::new_v4()
    ));
    fs::write(&temp, bytes)?;
    let backup = path.with_extension("json.bak");
    if path.exists() {
        if backup.exists() {
            fs::remove_file(&backup)?;
        }
        fs::rename(path, &backup)?;
    }
    match fs::rename(&temp, path) {
        Ok(()) => {
            if backup.exists() {
                let _ = fs::remove_file(backup);
            }
            Ok(())
        }
        Err(error) => {
            if backup.exists() {
                let _ = fs::rename(&backup, path);
            }
            let _ = fs::remove_file(temp);
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account(id: &str, used: f64, active: bool) -> Account {
        Account {
            id: id.into(),
            email: format!("{id}@example.com"),
            openai_account_id: id.into(),
            plan_type: "plus".into(),
            primary_used_percent: used,
            secondary_used_percent: 0.0,
            primary_reset_at: None,
            secondary_reset_at: None,
            last_checked: None,
            is_active: active,
            is_suspended: false,
            token_expired: false,
            organization_name: None,
        }
    }

    #[test]
    fn public_config_never_serializes_tokens() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("config.json")).unwrap();
        store.save().unwrap();
        let text = fs::read_to_string(dir.path().join("config.json")).unwrap();
        assert!(!text.contains("access_token"));
        assert!(!text.contains("refresh_token"));
        assert!(!text.contains("id_token"));
    }

    #[test]
    fn opens_missing_config_with_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("nested/config.json")).unwrap();
        assert_eq!(store.config().version, 2);
        assert!(store.accounts().is_empty());
        store.save().unwrap();
        assert!(dir.path().join("nested/config.json").exists());
    }

    #[test]
    fn auto_route_selects_the_healthy_account_with_most_remaining_usage() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("config.json")).unwrap();
        store.config.auto_route_enabled = true;
        store.config.auto_route_threshold = 90.0;
        store.config.accounts = vec![
            account("current", 95.0, true),
            account("candidate-high", 60.0, false),
            account("candidate-best", 20.0, false),
        ];
        assert_eq!(
            store.auto_route_if_needed().unwrap().as_deref(),
            Some("candidate-best")
        );
        assert!(store.account("candidate-best").unwrap().is_active);
    }
}
