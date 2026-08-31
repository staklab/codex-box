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

pub fn themes_root() -> anyhow::Result<PathBuf> {
    Ok(app_root()?.join("themes"))
}

pub fn local_themes_root() -> anyhow::Result<PathBuf> {
    Ok(app_root()?.join("themes-local"))
}

pub fn codex_config_path() -> anyhow::Result<PathBuf> {
    Ok(codex_root()?.join("config.toml"))
}

pub fn thread_presets_path() -> anyhow::Result<PathBuf> {
    Ok(app_root()?.join("desktop-thread-presets.json"))
}

pub fn ensure_directories() -> anyhow::Result<()> {
    std::fs::create_dir_all(app_root()?)?;
    std::fs::create_dir_all(profiles_root()?)?;
    std::fs::create_dir_all(themes_root()?)?;
    std::fs::create_dir_all(local_themes_root()?)?;
    Ok(())
}
