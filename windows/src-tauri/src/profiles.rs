use crate::models::Profile;
use crate::paths;
use chrono::Utc;
use std::process::{Child, Command, Stdio};

pub fn create(name: String, account_id: Option<String>) -> anyhow::Result<Profile> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        anyhow::bail!("档案名称不能为空");
    }
    let id = uuid::Uuid::new_v4().to_string();
    let home = paths::profiles_root()?.join(&id).join("codex-home");
    std::fs::create_dir_all(&home)?;
    Ok(Profile {
        id,
        name: trimmed.to_owned(),
        account_id,
        codex_home: home.to_string_lossy().into_owned(),
        created_at: Utc::now(),
    })
}

pub fn launch(profile: &Profile, gateway: Option<(&str, &str)>) -> anyhow::Result<Child> {
    let mut command = Command::new("codex");
    command
        .env("CODEX_HOME", &profile.codex_home)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some((base_url, api_key)) = gateway {
        command
            .env("OPENAI_BASE_URL", base_url)
            .env("OPENAI_API_KEY", api_key);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
        .spawn()
        .map_err(|error| anyhow::anyhow!("无法启动 Codex CLI，请确认已安装并加入 PATH：{error}"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn empty_profile_name_is_rejected() {
        assert!(super::create("  ".into(), None).is_err());
    }
}
