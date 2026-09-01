use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use tauri::{Emitter, Manager};

const RELEASE_URL: &str = "https://api.github.com/repos/staklab/codex-box/releases/latest";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub version: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedUpdate {
    pub version: String,
}

#[derive(Debug, Clone)]
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub struct ReadyInstaller {
    version: String,
    path: PathBuf,
    kind: InstallerKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InstallerKind {
    Nsis,
    Msi,
}

#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    assets: Vec<Asset>,
}

#[derive(Debug, Clone, Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
    size: u64,
    digest: Option<String>,
}

#[derive(Serialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
struct DownloadProgress {
    downloaded: u64,
    total: u64,
}

fn client() -> anyhow::Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .user_agent("codex-box-windows")
        .timeout(std::time::Duration::from_secs(30))
        .build()?)
}

fn installer_kind(name: &str) -> Option<InstallerKind> {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".exe") && (lower.contains("setup") || lower.contains("installer")) {
        Some(InstallerKind::Nsis)
    } else if lower.ends_with(".msi") {
        Some(InstallerKind::Msi)
    } else {
        None
    }
}

fn select_installer(release: &Release) -> Option<(&Asset, InstallerKind)> {
    release
        .assets
        .iter()
        .filter_map(|asset| installer_kind(&asset.name).map(|kind| (asset, kind)))
        .min_by_key(|(_, kind)| if *kind == InstallerKind::Nsis { 0 } else { 1 })
}

async fn fetch_release(url: &str) -> anyhow::Result<Release> {
    Ok(client()?
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .json::<Release>()
        .await?)
}

fn newer_installer<'a>(
    release: &'a Release,
    current: &str,
) -> anyhow::Result<Option<(&'a Asset, InstallerKind, String)>> {
    let latest = release.tag_name.trim_start_matches('v');
    if semver::Version::parse(latest)? <= semver::Version::parse(current)? {
        return Ok(None);
    }
    Ok(select_installer(release).map(|(asset, kind)| (asset, kind, latest.to_owned())))
}

pub async fn check(current: &str) -> anyhow::Result<Option<UpdateInfo>> {
    let release = fetch_release(RELEASE_URL).await?;
    Ok(
        newer_installer(&release, current)?.map(|(asset, _, version)| UpdateInfo {
            version,
            size: asset.size,
        }),
    )
}

fn expected_sha256(asset: &Asset) -> anyhow::Result<&str> {
    asset
        .digest
        .as_deref()
        .and_then(|value| value.strip_prefix("sha256:"))
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| anyhow::anyhow!("Release 安装包缺少有效的 SHA-256 摘要"))
}

fn safe_asset_name(name: &str) -> anyhow::Result<&str> {
    let path = Path::new(name);
    if path.file_name().and_then(|value| value.to_str()) == Some(name) {
        Ok(name)
    } else {
        anyhow::bail!("Release 安装包名称无效")
    }
}

pub async fn download(app: &tauri::AppHandle, current: &str) -> anyhow::Result<ReadyInstaller> {
    let release = fetch_release(RELEASE_URL).await?;
    let (asset, kind, version) = newer_installer(&release, current)?
        .ok_or_else(|| anyhow::anyhow!("当前没有可下载的 Windows 更新"))?;
    let expected = expected_sha256(asset)?.to_ascii_lowercase();
    let name = safe_asset_name(&asset.name)?;
    let directory = app.path().app_cache_dir()?.join("updates").join(&version);
    tokio::fs::create_dir_all(&directory).await?;
    let destination = directory.join(name);
    let temporary = directory.join(format!("{name}.download"));

    let response = client()?
        .get(&asset.browser_download_url)
        .send()
        .await?
        .error_for_status()?;
    let total = response.content_length().unwrap_or(asset.size);
    let mut stream = response.bytes_stream();
    let mut file = tokio::fs::File::create(&temporary).await?;
    let mut hasher = Sha256::new();
    let mut downloaded = 0_u64;
    use tokio::io::AsyncWriteExt;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        hasher.update(&chunk);
        downloaded += chunk.len() as u64;
        let _ = app.emit(
            "update-download-progress",
            DownloadProgress { downloaded, total },
        );
    }
    file.flush().await?;
    drop(file);
    let actual = format!("{:x}", hasher.finalize());
    if actual != expected {
        let _ = tokio::fs::remove_file(&temporary).await;
        anyhow::bail!("更新安装包校验失败，已丢弃下载文件")
    }
    if destination.exists() {
        tokio::fs::remove_file(&destination).await?;
    }
    tokio::fs::rename(&temporary, &destination).await?;
    Ok(ReadyInstaller {
        version,
        path: destination,
        kind,
    })
}

pub fn prepared(installer: &ReadyInstaller) -> PreparedUpdate {
    PreparedUpdate {
        version: installer.version.clone(),
    }
}

#[cfg(target_os = "windows")]
pub fn launch_installer(installer: &ReadyInstaller) -> anyhow::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let pid = std::process::id().to_string();
    let current_exe = std::env::current_exe()?;
    let (program, install_args): (&str, Vec<String>) = match installer.kind {
        InstallerKind::Nsis => (
            installer
                .path
                .to_str()
                .ok_or_else(|| anyhow::anyhow!("安装包路径无效"))?,
            vec!["/S".to_owned()],
        ),
        InstallerKind::Msi => (
            "msiexec.exe",
            vec![
                "/i".to_owned(),
                installer.path.to_string_lossy().into_owned(),
                "/qn".to_owned(),
                "/norestart".to_owned(),
            ],
        ),
    };
    let install_args = install_args
        .into_iter()
        .map(|value| powershell_literal(&value))
        .collect::<Vec<_>>()
        .join(",");
    let program = powershell_literal(program);
    let current_exe = powershell_literal(&current_exe.to_string_lossy());
    let script = format!(
        "$targetPid={pid};$program={program};$app={current_exe};Wait-Process -Id $targetPid -ErrorAction SilentlyContinue;Start-Process -FilePath $program -ArgumentList @({install_args}) -Wait;Start-Process -FilePath $app"
    );
    std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            &script,
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()?;
    Ok(())
}

#[cfg(any(target_os = "windows", test))]
fn powershell_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(not(target_os = "windows"))]
pub fn launch_installer(_installer: &ReadyInstaller) -> anyhow::Result<()> {
    anyhow::bail!("自动安装仅可在 Windows 上运行")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str, assets: &[(&str, Option<&str>)]) -> Release {
        Release {
            tag_name: tag.to_owned(),
            assets: assets
                .iter()
                .map(|(name, digest)| Asset {
                    name: (*name).to_owned(),
                    browser_download_url: format!("https://example.com/{name}"),
                    size: 42,
                    digest: digest.map(str::to_owned),
                })
                .collect(),
        }
    }

    #[test]
    fn semantic_versions_do_not_use_lexical_order() {
        let release = release("v1.10.0", &[("codex-box_1.10.0_x64-setup.exe", None)]);
        assert!(newer_installer(&release, "1.9.0").unwrap().is_some());
    }

    #[test]
    fn release_without_windows_installer_is_not_reported() {
        let release = release("v2.0.0", &[("codex-box-2.0.0-macOS.dmg", None)]);
        assert!(newer_installer(&release, "1.0.0").unwrap().is_none());
    }

    #[test]
    fn prefers_nsis_and_rejects_plain_executable() {
        let release = release(
            "v2.0.0",
            &[
                ("codex-box.exe", None),
                ("codex-box_2.0.0_x64_en-US.msi", None),
                ("codex-box_2.0.0_x64-setup.exe", None),
            ],
        );
        let (asset, kind) = select_installer(&release).unwrap();
        assert_eq!(asset.name, "codex-box_2.0.0_x64-setup.exe");
        assert_eq!(kind, InstallerKind::Nsis);
    }

    #[test]
    fn checksum_is_mandatory_and_validated() {
        let valid = format!("sha256:{}", "a".repeat(64));
        let valid_release = release("v2.0.0", &[("setup.exe", Some(&valid))]);
        assert_eq!(
            expected_sha256(&valid_release.assets[0]).unwrap(),
            "a".repeat(64)
        );
        let invalid = release("v2.0.0", &[("setup.exe", None)]);
        assert!(expected_sha256(&invalid.assets[0]).is_err());
    }

    #[test]
    fn powershell_paths_are_single_quoted_without_command_injection() {
        assert_eq!(
            powershell_literal("C:\\O'Brien\\setup.exe"),
            "'C:\\O''Brien\\setup.exe'"
        );
    }
}
