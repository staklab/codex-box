use std::path::PathBuf;

pub fn home_dir() -> anyhow::Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| anyhow::anyhow!("无法确定用户主目录"))
}

pub fn app_root() -> anyhow::Result<PathBuf> {
    Ok(home_dir()?.join(".codex-box"))
}

pub fn codex_root() -> anyhow::Result<PathBuf> {
    Ok(home_dir()?.join(".codex"))
}

pub fn config_path() -> anyhow::Result<PathBuf> {
    Ok(app_root()?.join("windows-config.json"))
}

pub fn profiles_root() -> anyhow::Result<PathBuf> {
    Ok(app_root()?.join("profiles"))
}

pub fn ensure_directories() -> anyhow::Result<()> {
    std::fs::create_dir_all(app_root()?)?;
    std::fs::create_dir_all(profiles_root()?)?;
    Ok(())
}
