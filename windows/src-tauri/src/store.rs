use crate::models::{Account, AccountCredentials, PublicConfig};
use crate::paths;
use std::fs;
use std::path::{Path, PathBuf};

const KEYRING_SERVICE: &str = "com.codexbox.windows.oauth";

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

impl Store {
    pub fn open_default() -> Result<Self, StoreError> {
        paths::ensure_directories()?;
        Self::open(paths::config_path()?)
    }

    pub fn open(path: PathBuf) -> Result<Self, StoreError> {
        let config = if path.exists() {
            serde_json::from_slice(&fs::read(&path)?)?
        } else {
            PublicConfig {
                version: 1,
                ..Default::default()
            }
        };
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
        assert_eq!(store.config().version, 1);
        assert!(store.accounts().is_empty());
        store.save().unwrap();
        assert!(dir.path().join("nested/config.json").exists());
    }
}
