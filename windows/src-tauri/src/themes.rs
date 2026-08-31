use crate::config_edit;
use crate::models::{
    InstalledTheme, ThemeColors, ThemeListing, ThemePage, ThemeSource, ThemeState,
};
use crate::paths;
use chrono::Utc;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

const MAX_INDEX_BYTES: usize = 8 * 1024 * 1024;
const MAX_PACKAGE_BYTES: usize = 64 * 1024 * 1024;
const DREAMSKIN_PAGE_SIZE: usize = 24;
const DREAMSKIN_PAGE_LIMIT: usize = 5;
type ThemeImage = (Vec<u8>, String);
type ThemeAssets = (Vec<u8>, Option<ThemeImage>);

pub fn built_in_sources() -> Vec<ThemeSource> {
    vec![
        ThemeSource {
            id: "codexplusplus".into(),
            name: "CodexPlusPlus Themes（聚合库）".into(),
            base_url: "https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlus-Themes/main"
                .into(),
            enabled: true,
            format: "codexPlusPlus".into(),
        },
        ThemeSource {
            id: "dreamskin-cc".into(),
            name: "DreamSkin.cc（社区大库）".into(),
            base_url: "https://api.dreamskin.cc".into(),
            enabled: true,
            format: "dreamSkinAPI".into(),
        },
        ThemeSource {
            id: "awesome-codex-skins".into(),
            name: "Awesome Codex Skins（.codexskin 标准库）".into(),
            base_url:
                "https://raw.githubusercontent.com/Wangnov/awesome-codex-skins/main/dist-catalog"
                    .into(),
            enabled: true,
            format: "codexSkinPack".into(),
        },
    ]
}

pub async fn refresh_market(sources: &[ThemeSource]) -> (Vec<ThemeListing>, Vec<String>) {
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(client) => client,
        Err(error) => return (Vec::new(), vec![error.to_string()]),
    };
    let mut merged = Vec::new();
    let mut issues = Vec::new();
    for source in sources.iter().filter(|source| source.enabled) {
        let result = if source.format == "dreamSkinAPI" {
            fetch_dreamskin(&client, source).await
        } else {
            fetch_catalog(&client, source).await
        };
        match result {
            Ok(items) => merged.extend(items),
            Err(error) => issues.push(format!("{}：{error}", source.name)),
        }
    }
    match local_listings() {
        Ok(items) => merged.extend(items),
        Err(error) => issues.push(format!("本地主题：{error}")),
    }
    let mut seen = HashSet::new();
    merged.retain(|item| seen.insert(format!("{}|{}", item.source_name, item.id)));
    (merged, issues)
}

pub fn paginate(
    catalog: &[ThemeListing],
    issues: Vec<String>,
    offset: usize,
    limit: usize,
    query: &str,
) -> ThemePage {
    let query = query.trim().to_lowercase();
    let filtered: Vec<_> = catalog
        .iter()
        .filter(|item| {
            query.is_empty()
                || item.name.to_lowercase().contains(&query)
                || item.id.to_lowercase().contains(&query)
                || item
                    .author
                    .as_deref()
                    .unwrap_or_default()
                    .to_lowercase()
                    .contains(&query)
                || item
                    .tags
                    .iter()
                    .any(|tag| tag.to_lowercase().contains(&query))
        })
        .cloned()
        .collect();
    let total = filtered.len();
    let offset = offset.min(total);
    let limit = limit.clamp(1, 48);
    ThemePage {
        items: filtered.into_iter().skip(offset).take(limit).collect(),
        total,
        offset,
        limit,
        issues,
    }
}

async fn fetch_catalog(
    client: &reqwest::Client,
    source: &ThemeSource,
) -> anyhow::Result<Vec<ThemeListing>> {
    let bytes = fetch_bytes(
        client,
        &format!("{}/index.json", source.base_url),
        MAX_INDEX_BYTES,
    )
    .await?;
    let value: Value = serde_json::from_slice(&bytes)?;
    if let Some(items) = value.get("themes").and_then(Value::as_array) {
        return items
            .iter()
            .map(|item| listing_from_theme(item, source))
            .collect();
    }
    if let Some(items) = value.get("skins").and_then(Value::as_array) {
        return items
            .iter()
            .map(|item| listing_from_pack(item, source))
            .collect();
    }
    anyhow::bail!("市场索引格式无效")
}

fn listing_from_theme(item: &Value, source: &ThemeSource) -> anyhow::Result<ThemeListing> {
    Ok(ThemeListing {
        id: required_string(item, "id")?,
        name: required_string(item, "name")?,
        version: string(item, "version").unwrap_or_else(|| "1.0.0".into()),
        author: string(item, "author"),
        description: string(item, "description"),
        license: string(item, "license"),
        tags: strings(item.get("tags")),
        theme: required_string(item, "theme")?,
        preview: string(item, "preview").or_else(|| string(item, "image")),
        source_base_url: source.base_url.clone(),
        source_name: source.name.clone(),
        is_pack: false,
        declared_sha256: None,
        inline_colors: None,
        inline_appearance: None,
    })
}

fn listing_from_pack(item: &Value, source: &ThemeSource) -> anyhow::Result<ThemeListing> {
    Ok(ThemeListing {
        id: required_string(item, "id")?,
        name: required_string(item, "name")?,
        version: string(item, "version").unwrap_or_else(|| "1.0.0".into()),
        author: string(item, "author"),
        description: string(item, "description"),
        license: string(item, "license"),
        tags: strings(item.get("tags")),
        theme: required_string(item, "pack")?,
        preview: string(item, "preview"),
        source_base_url: source.base_url.clone(),
        source_name: source.name.clone(),
        is_pack: true,
        declared_sha256: string(item, "sha256"),
        inline_colors: None,
        inline_appearance: string(item, "appearance"),
    })
}

async fn fetch_dreamskin(
    client: &reqwest::Client,
    source: &ThemeSource,
) -> anyhow::Result<Vec<ThemeListing>> {
    let mut output = Vec::new();
    for page in 0..DREAMSKIN_PAGE_LIMIT {
        let offset = page * DREAMSKIN_PAGE_SIZE;
        let url = format!(
            "{}/v1/themes?limit={DREAMSKIN_PAGE_SIZE}&offset={offset}",
            source.base_url
        );
        let bytes = fetch_bytes(client, &url, MAX_INDEX_BYTES).await?;
        let value: Value = serde_json::from_slice(&bytes)?;
        let items = value
            .get("items")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow::anyhow!("DreamSkin 返回格式无效"))?;
        for item in items {
            output.push(listing_from_dreamskin(item, source)?);
        }
        let total = value.get("total").and_then(Value::as_u64).unwrap_or(0) as usize;
        if items.is_empty() || offset + items.len() >= total {
            break;
        }
    }
    Ok(output)
}

fn listing_from_dreamskin(item: &Value, source: &ThemeSource) -> anyhow::Result<ThemeListing> {
    let version_id = required_string(item, "id")?;
    let display = item.get("displayMeta").cloned().unwrap_or(Value::Null);
    let colors = display
        .get("colors")
        .cloned()
        .and_then(|colors| serde_json::from_value(colors).ok());
    Ok(ThemeListing {
        id: string(item, "themeId").unwrap_or_else(|| version_id.clone()),
        name: required_string(item, "name")?,
        version: string(item, "version").unwrap_or_else(|| "1.0.0".into()),
        author: string(item, "authorDisplayName"),
        description: item
            .get("downloadCount")
            .and_then(Value::as_u64)
            .map(|count| format!("下载 {count} 次")),
        license: string(item, "license"),
        tags: string(&display, "appearance").into_iter().collect(),
        theme: format!("/v1/themes/{version_id}/download"),
        preview: Some(format!("/v1/themes/{version_id}/preview/thumbnail")),
        source_base_url: source.base_url.clone(),
        source_name: source.name.clone(),
        is_pack: true,
        declared_sha256: string(item, "packageSha256"),
        inline_colors: colors,
        inline_appearance: string(&display, "appearance"),
    })
}

pub async fn fetch_dreamskin_version(version_id: &str) -> anyhow::Result<ThemeListing> {
    if !version_id.starts_with("ver_")
        || !version_id
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
    {
        anyhow::bail!("DreamSkin 版本 ID 无效")
    }
    let source = built_in_sources()
        .into_iter()
        .find(|source| source.id == "dreamskin-cc")
        .expect("内置 DreamSkin 源");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    let bytes = fetch_bytes(
        &client,
        &format!("{}/v1/themes/{version_id}", source.base_url),
        MAX_INDEX_BYTES,
    )
    .await?;
    let value: Value = serde_json::from_slice(&bytes)?;
    if value.get("id").and_then(Value::as_str) != Some(version_id) {
        anyhow::bail!("DreamSkin 主题不存在")
    }
    let platforms = strings(value.pointer("/displayMeta/platforms"));
    if !platforms.is_empty()
        && !platforms.iter().any(|platform| {
            platform.eq_ignore_ascii_case("windows") || platform.eq_ignore_ascii_case("all")
        })
    {
        anyhow::bail!("该 DreamSkin 版本未声明支持 Windows")
    }
    listing_from_dreamskin(&value, &source)
}

pub async fn install(
    listing: &ThemeListing,
    state: &ThemeState,
) -> anyhow::Result<(InstalledTheme, PathBuf)> {
    let destination = theme_directory(&listing.id)?;
    std::fs::create_dir_all(&destination)?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    let (theme_data, image) = if let Some(colors) = &listing.inline_colors {
        let definition = json!({
            "schemaVersion": 1,
            "id": listing.id,
            "name": listing.name,
            "colors": colors,
            "appearance": listing.inline_appearance,
        });
        let theme = serde_json::to_vec_pretty(&definition)?;
        let image = match fetch_listing_bytes(&client, listing, MAX_PACKAGE_BYTES).await {
            Ok(pack) => {
                verify_declared_hash(listing, &pack)?;
                extract_theme_pack(&pack).ok().and_then(|(_, image)| image)
            }
            Err(_) => None,
        };
        (theme, image)
    } else if listing.is_pack {
        let pack = fetch_listing_bytes(&client, listing, MAX_PACKAGE_BYTES).await?;
        verify_declared_hash(listing, &pack)?;
        extract_theme_pack(&pack)?
    } else if listing.source_base_url == "local://" {
        read_local_theme(&listing.id)?
    } else {
        let theme = fetch_url_bytes(
            &client,
            &listing.source_base_url,
            &listing.theme,
            MAX_INDEX_BYTES,
        )
        .await?;
        (theme, None)
    };

    serde_json::from_slice::<Value>(&theme_data)
        .map_err(|error| anyhow::anyhow!("theme.json 无效：{error}"))?;
    let theme_hash = sha256_hex(&theme_data);
    if let Some(existing) = state
        .installed
        .iter()
        .find(|theme| theme.id == listing.id && theme.version == listing.version)
    {
        if existing.theme_sha256 != theme_hash {
            anyhow::bail!("主题内容与首次安装摘要不一致")
        }
    }
    std::fs::write(destination.join("theme.json"), &theme_data)?;
    let (image_sha256, has_image) = if let Some((bytes, extension)) = image {
        let digest = sha256_hex(&bytes);
        std::fs::write(destination.join(format!("image.{extension}")), bytes)?;
        (Some(digest), true)
    } else {
        (None, false)
    };
    Ok((
        InstalledTheme {
            id: listing.id.clone(),
            name: listing.name.clone(),
            version: listing.version.clone(),
            installed_at: Utc::now(),
            theme_sha256: theme_hash,
            image_sha256,
            has_image,
        },
        destination,
    ))
}

pub fn import_local_theme(source: &Path) -> anyhow::Result<ThemeListing> {
    let source = source.canonicalize()?;
    let theme_path = source.join("theme.json");
    let data = std::fs::read(&theme_path)?;
    let definition: Value = serde_json::from_slice(&data)?;
    let raw_id = string(&definition, "id")
        .or_else(|| {
            source
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .ok_or_else(|| anyhow::anyhow!("主题缺少 id"))?;
    let id = slug(&raw_id);
    if id.is_empty() {
        anyhow::bail!("主题 id 无效")
    }
    let target = paths::local_themes_root()?.join(&id);
    std::fs::create_dir_all(&target)?;
    std::fs::write(target.join("theme.json"), data)?;
    for name in image_candidates() {
        let candidate = source.join(name);
        if candidate.exists() {
            std::fs::copy(&candidate, target.join(name))?;
            break;
        }
    }
    Ok(local_listing(&target, &id, &definition))
}

fn local_listings() -> anyhow::Result<Vec<ThemeListing>> {
    let root = paths::local_themes_root()?;
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut result = Vec::new();
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let theme = entry.path().join("theme.json");
        let Ok(data) = std::fs::read(theme) else {
            continue;
        };
        let Ok(definition) = serde_json::from_slice::<Value>(&data) else {
            continue;
        };
        let id = entry.file_name().to_string_lossy().into_owned();
        result.push(local_listing(&entry.path(), &id, &definition));
    }
    Ok(result)
}

fn local_listing(_directory: &Path, id: &str, definition: &Value) -> ThemeListing {
    ThemeListing {
        id: id.into(),
        name: string(definition, "name").unwrap_or_else(|| id.into()),
        version: "local".into(),
        author: None,
        description: string(definition, "tagline"),
        license: None,
        tags: vec!["本地".into()],
        theme: "theme.json".into(),
        preview: None,
        source_base_url: "local://".into(),
        source_name: "本地主题库".into(),
        is_pack: false,
        declared_sha256: None,
        inline_colors: None,
        inline_appearance: string(definition, "appearance"),
    }
}

fn read_local_theme(id: &str) -> anyhow::Result<ThemeAssets> {
    let directory = paths::local_themes_root()?.join(id);
    let theme = std::fs::read(directory.join("theme.json"))?;
    let image = read_image(&directory)?;
    Ok((theme, image))
}

pub fn load_definition(id: &str) -> anyhow::Result<(ThemeColors, PathBuf)> {
    let directory = theme_directory(id)?;
    let data = std::fs::read(directory.join("theme.json"))?;
    let value: Value = serde_json::from_slice(&data)?;
    let colors = value
        .get("colors")
        .cloned()
        .and_then(|colors| serde_json::from_value(colors).ok())
        .unwrap_or_default();
    Ok((colors, directory))
}

pub fn revert_native_colors() -> anyhow::Result<()> {
    let path = paths::codex_config_path()?;
    let mut updated = std::fs::read_to_string(&path).unwrap_or_default();
    for table in [
        "desktop.appearanceLightChromeTheme.semanticColors",
        "desktop.appearanceDarkChromeTheme.semanticColors",
        "desktop.appearanceLightChromeTheme",
        "desktop.appearanceDarkChromeTheme",
    ] {
        updated = config_edit::remove_table(&updated, table);
    }
    config_edit::write_with_backup(&path, &updated, "config.toml.bak-codexbox-theme")
}

pub fn uninstall(id: &str) -> anyhow::Result<()> {
    let target = theme_directory(id)?;
    let root = paths::themes_root()?.canonicalize()?;
    if target.exists() {
        let target = target.canonicalize()?;
        if !target.starts_with(root) {
            anyhow::bail!("拒绝删除主题目录之外的路径")
        }
        std::fs::remove_dir_all(target)?;
    }
    Ok(())
}

fn theme_directory(id: &str) -> anyhow::Result<PathBuf> {
    let id = slug(id);
    if id.is_empty() {
        anyhow::bail!("主题 id 无效")
    }
    Ok(paths::themes_root()?.join(id))
}

fn slug(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
        .collect()
}

async fn fetch_listing_bytes(
    client: &reqwest::Client,
    listing: &ThemeListing,
    limit: usize,
) -> anyhow::Result<Vec<u8>> {
    fetch_url_bytes(client, &listing.source_base_url, &listing.theme, limit).await
}

async fn fetch_url_bytes(
    client: &reqwest::Client,
    base: &str,
    relative: &str,
    limit: usize,
) -> anyhow::Result<Vec<u8>> {
    let base = url::Url::parse(&format!("{}/", base.trim_end_matches('/')))?;
    let url = base.join(relative.trim_start_matches('/'))?;
    fetch_bytes(client, url.as_str(), limit).await
}

async fn fetch_bytes(client: &reqwest::Client, url: &str, limit: usize) -> anyhow::Result<Vec<u8>> {
    let response = client.get(url).send().await?.error_for_status()?;
    if response
        .content_length()
        .is_some_and(|size| size > limit as u64)
    {
        anyhow::bail!("下载内容超过 {} MiB 限制", limit / 1024 / 1024)
    }
    let bytes = response.bytes().await?;
    if bytes.len() > limit {
        anyhow::bail!("下载内容超过 {} MiB 限制", limit / 1024 / 1024)
    }
    Ok(bytes.to_vec())
}

fn extract_theme_pack(bytes: &[u8]) -> anyhow::Result<ThemeAssets> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))?;
    let mut theme = None;
    let mut image: Option<(Vec<u8>, String)> = None;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let Some(path) = entry.enclosed_name() else {
            continue;
        };
        if entry.is_dir() || entry.size() > MAX_PACKAGE_BYTES as u64 {
            continue;
        }
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        if file_name.eq_ignore_ascii_case("theme.json") {
            let mut data = Vec::new();
            entry.read_to_end(&mut data)?;
            theme = Some(data);
            continue;
        }
        let extension = path
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or_default()
            .to_lowercase();
        if matches!(extension.as_str(), "png" | "jpg" | "jpeg" | "webp") {
            let should_replace = image
                .as_ref()
                .is_none_or(|(data, _)| entry.size() as usize > data.len());
            if should_replace {
                let mut data = Vec::new();
                entry.read_to_end(&mut data)?;
                image = Some((
                    data,
                    if extension == "jpeg" {
                        "jpg".into()
                    } else {
                        extension
                    },
                ));
            }
        }
    }
    let theme = theme.ok_or_else(|| anyhow::anyhow!("主题包缺少 theme.json"))?;
    Ok((theme, image))
}

fn verify_declared_hash(listing: &ThemeListing, bytes: &[u8]) -> anyhow::Result<()> {
    if let Some(expected) = listing
        .declared_sha256
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        if expected.len() != 64
            || !expected
                .chars()
                .all(|character| character.is_ascii_hexdigit())
        {
            anyhow::bail!("主题包 SHA-256 声明无效")
        }
        let actual = sha256_hex(bytes);
        if actual != expected.to_lowercase() {
            anyhow::bail!("主题包 SHA-256 校验失败")
        }
    }
    Ok(())
}

fn read_image(directory: &Path) -> anyhow::Result<Option<(Vec<u8>, String)>> {
    for name in image_candidates() {
        let path = directory.join(name);
        if path.exists() {
            let extension = path
                .extension()
                .and_then(|extension| extension.to_str())
                .unwrap_or("png")
                .to_lowercase();
            return Ok(Some((std::fs::read(path)?, extension)));
        }
    }
    Ok(None)
}

fn image_candidates() -> [&'static str; 8] {
    [
        "image.png",
        "image.jpg",
        "image.jpeg",
        "image.webp",
        "background.png",
        "background.jpg",
        "wallpaper.png",
        "wallpaper.jpg",
    ]
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn required_string(value: &Value, key: &str) -> anyhow::Result<String> {
    string(value, key).ok_or_else(|| anyhow::anyhow!("主题条目缺少 {key}"))
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn listing(id: &str) -> ThemeListing {
        ThemeListing {
            id: id.into(),
            name: id.into(),
            version: "1".into(),
            author: None,
            description: None,
            license: None,
            tags: vec![],
            theme: "theme.json".into(),
            preview: None,
            source_base_url: "local://".into(),
            source_name: "local".into(),
            is_pack: false,
            declared_sha256: None,
            inline_colors: None,
            inline_appearance: None,
        }
    }

    #[test]
    fn market_page_is_strictly_bounded() {
        let catalog: Vec<_> = (0..200)
            .map(|index| listing(&format!("theme-{index}")))
            .collect();
        let page = paginate(&catalog, vec![], 0, 24, "");
        assert_eq!(page.items.len(), 24);
        assert_eq!(page.total, 200);
        let oversized = paginate(&catalog, vec![], 0, 500, "");
        assert_eq!(oversized.items.len(), 48);
    }

    #[test]
    fn rejects_path_like_theme_ids() {
        assert_eq!(slug("../../evil"), "evil");
        assert_eq!(slug("合法-theme_1"), "-theme_1");
    }

    #[test]
    fn rejects_abbreviated_or_mismatched_package_hashes() {
        let mut item = listing("safe");
        item.declared_sha256 = Some("a".into());
        assert!(verify_declared_hash(&item, b"theme").is_err());
        item.declared_sha256 = Some("0".repeat(64));
        assert!(verify_declared_hash(&item, b"theme").is_err());
        item.declared_sha256 = Some(sha256_hex(b"theme"));
        assert!(verify_declared_hash(&item, b"theme").is_ok());
    }

    #[test]
    fn theme_pack_ignores_parent_directory_entries() {
        let mut archive = zip::ZipWriter::new(Cursor::new(Vec::new()));
        archive
            .start_file("../theme.json", zip::write::SimpleFileOptions::default())
            .unwrap();
        archive.write_all(br#"{"name":"unsafe"}"#).unwrap();
        let bytes = archive.finish().unwrap().into_inner();
        assert!(extract_theme_pack(&bytes).is_err());
    }
}
