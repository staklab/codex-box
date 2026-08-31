use std::path::Path;

pub fn root_value(text: &str, key: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            break;
        }
        if let Some((candidate, value)) = trimmed.split_once('=') {
            if candidate.trim() == key {
                return Some(value.trim().to_owned());
            }
        }
    }
    None
}

pub fn upsert_root_key(text: &str, key: &str, value: &str) -> String {
    let mut lines: Vec<String> = text.lines().map(str::to_owned).collect();
    let table_start = lines
        .iter()
        .position(|line| line.trim_start().starts_with('['))
        .unwrap_or(lines.len());
    if let Some(index) = lines[..table_start].iter().position(|line| {
        line.split_once('=')
            .is_some_and(|(candidate, _)| candidate.trim() == key)
    }) {
        lines[index] = format!("{key} = {value}");
    } else {
        lines.insert(table_start, format!("{key} = {value}"));
    }
    finish(lines)
}

pub fn remove_table(text: &str, table: &str) -> String {
    replace_table_inner(text, table, None)
}

#[cfg(test)]
pub fn replace_table(text: &str, table: &str, body: &[String]) -> String {
    replace_table_inner(text, table, Some(body))
}

fn replace_table_inner(text: &str, table: &str, body: Option<&[String]>) -> String {
    let mut lines: Vec<String> = text.lines().map(str::to_owned).collect();
    let header = format!("[{table}]");
    if let Some(start) = lines.iter().position(|line| line.trim() == header) {
        let end = lines[start + 1..]
            .iter()
            .position(|line| line.trim_start().starts_with('['))
            .map(|offset| start + 1 + offset)
            .unwrap_or(lines.len());
        lines.drain(start..end);
    }
    if let Some(body) = body {
        while lines.last().is_some_and(|line| line.trim().is_empty()) {
            lines.pop();
        }
        if !lines.is_empty() {
            lines.push(String::new());
        }
        lines.push(header);
        lines.extend(body.iter().cloned());
    }
    finish(lines)
}

fn finish(lines: Vec<String>) -> String {
    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

pub fn write_with_backup(path: &Path, text: &str, backup_name: &str) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        if path.exists() {
            std::fs::copy(path, parent.join(backup_name))?;
        }
    }
    let temp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    std::fs::write(&temp, text.as_bytes())?;
    let rollback = path.with_extension(format!("rollback-{}", uuid::Uuid::new_v4()));
    if path.exists() {
        std::fs::rename(path, &rollback)?;
    }
    match std::fs::rename(&temp, path) {
        Ok(()) => {
            if rollback.exists() {
                let _ = std::fs::remove_file(rollback);
            }
            Ok(())
        }
        Err(error) => {
            if rollback.exists() {
                let _ = std::fs::rename(&rollback, path);
            }
            let _ = std::fs::remove_file(temp);
            Err(error.into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_only_requested_root_key() {
        let original = "model = \"old\"\n[other]\nmodel = \"keep\"\n";
        let updated = upsert_root_key(original, "model", "\"new\"");
        assert!(updated.starts_with("model = \"new\""));
        assert!(updated.contains("[other]\nmodel = \"keep\""));
    }

    #[test]
    fn replaces_one_table_without_touching_neighbors() {
        let original = "x = 1\n[a]\ny = 2\n[b]\nz = 3\n";
        let updated = replace_table(original, "a", &["y = 4".into()]);
        assert!(updated.contains("[b]\nz = 3"));
        assert!(updated.contains("[a]\ny = 4"));
        assert!(!updated.contains("y = 2"));
    }
}
