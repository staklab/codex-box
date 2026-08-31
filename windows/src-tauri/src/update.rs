use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub version: String,
    pub download_url: String,
    pub release_url: String,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    html_url: String,
    assets: Vec<Asset>,
}
#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

pub async fn check(current: &str) -> anyhow::Result<Option<UpdateInfo>> {
    let release = reqwest::Client::new()
        .get("https://api.github.com/repos/staklab/codex-box/releases/latest")
        .header("user-agent", "codex-box-windows")
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await?
        .error_for_status()?
        .json::<Release>()
        .await?;
    let latest_text = release.tag_name.trim_start_matches('v');
    if semver::Version::parse(latest_text)? <= semver::Version::parse(current)? {
        return Ok(None);
    }
    let asset = release.assets.iter().find(|asset| {
        let lower = asset.name.to_ascii_lowercase();
        lower.ends_with(".exe") || lower.ends_with(".msi")
    });
    Ok(Some(UpdateInfo {
        version: latest_text.to_owned(),
        download_url: asset.map_or_else(
            || release.html_url.clone(),
            |asset| asset.browser_download_url.clone(),
        ),
        release_url: release.html_url,
    }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn semantic_versions_do_not_use_lexical_order() {
        assert!(
            semver::Version::parse("1.10.0").unwrap() > semver::Version::parse("1.9.0").unwrap()
        );
    }
}
