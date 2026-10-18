use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default)]
struct AppEntry {
    icon: Option<String>,
    name: Option<String>,
    rank: u8,
}

impl AppEntry {
    fn merge(self, weaker: AppEntry) -> AppEntry {
        AppEntry {
            icon: self.icon.or(weaker.icon),
            name: self.name.or(weaker.name),
            rank: self.rank,
        }
    }
}

pub struct IconIndex {
    by_exe: HashMap<String, AppEntry>,
    resolved: HashMap<String, Option<String>>,
    search_dirs: Vec<PathBuf>,
    defaults: Option<(Option<String>, Option<String>)>,
}

impl IconIndex {
    pub fn load() -> Self {
        let mut by_exe: HashMap<String, AppEntry> = HashMap::new();
        for dir in desktop_dirs() {
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                    continue;
                }
                if let Some((exe, found)) = parse_desktop(&path) {
                    match by_exe.get_mut(&exe) {
                        None => {
                            by_exe.insert(exe, found);
                        }
                        Some(slot) => {
                            let (primary, secondary) = if found.rank > slot.rank {
                                (found, std::mem::take(slot))
                            } else {
                                (std::mem::take(slot), found)
                            };
                            *slot = primary.merge(secondary);
                        }
                    }
                }
            }
        }
        Self {
            by_exe,
            resolved: HashMap::new(),
            search_dirs: icon_search_dirs(),
            defaults: None,
        }
    }

    pub fn icon_for(&mut self, exe_path: &str) -> Option<String> {
        let name = self.by_exe.get(&basename(exe_path))?.icon.clone()?;
        self.resolve(&name)
    }

    /// Human-readable app name (`Name=` of the matched desktop entry).
    pub fn name_for(&self, exe_path: &str) -> Option<String> {
        self.by_exe.get(&basename(exe_path))?.name.clone()
    }

    pub fn fallback_icon(&mut self, in_terminal: bool) -> Option<String> {
        if self.defaults.is_none() {
            let terminal = resolve_first(self, &["utilities-terminal", "terminal", "xterm"]);
            let generic = resolve_first(
                self,
                &[
                    "system-run",
                    "utilities-system-monitor",
                    "application-x-executable",
                ],
            );
            self.defaults = Some((terminal, generic));
        }
        let (terminal, generic) = self.defaults.as_ref()?;
        (if in_terminal { terminal } else { generic }).clone()
    }

    fn resolve(&mut self, name: &str) -> Option<String> {
        if let Some(hit) = self.resolved.get(name) {
            return hit.clone();
        }
        let found = if name.starts_with('/') {
            Path::new(name).is_file().then(|| name.to_string())
        } else {
            self.search_dirs.iter().find_map(|dir| {
                ["svg", "png", "xpm"].iter().find_map(|ext| {
                    let p = dir.join(format!("{name}.{ext}"));
                    p.is_file().then(|| p.to_string_lossy().to_string())
                })
            })
        };
        self.resolved.insert(name.to_string(), found.clone());
        found
    }
}

impl Default for IconIndex {
    fn default() -> Self {
        Self::load()
    }
}

fn resolve_first(icons: &mut IconIndex, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| icons.resolve(name))
}

fn desktop_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/share/applications"),
        PathBuf::from("/usr/local/share/applications"),
        PathBuf::from("/var/lib/flatpak/exports/share/applications"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(PathBuf::from(&home).join(".local/share/applications"));
        dirs.push(PathBuf::from(&home).join(".local/share/flatpak/exports/share/applications"));
    }
    dirs
}

fn icon_search_dirs() -> Vec<PathBuf> {
    let mut bases = vec![PathBuf::from("/usr/share/icons")];
    if let Ok(home) = std::env::var("HOME") {
        bases.push(PathBuf::from(&home).join(".local/share/icons"));
    }
    let themes = [
        "hicolor",
        "Adwaita",
        "AdwaitaLegacy",
        "Yaru",
        "breeze",
        "Papirus",
    ];
    let sizes = [
        "scalable", "256x256", "128x128", "64x64", "48x48", "32x32", "24x24", "16x16",
    ];
    // App icons live in `apps`; the fallback names are legacy/mimetype icons.
    let groups = ["apps", "legacy", "mimetypes"];
    let mut dirs = Vec::new();
    for base in &bases {
        for theme in themes {
            for size in sizes {
                for group in groups {
                    dirs.push(base.join(theme).join(size).join(group));
                }
            }
        }
    }
    dirs.push(PathBuf::from("/usr/share/pixmaps"));
    dirs
}

fn basename(exe_path: &str) -> String {
    Path::new(exe_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
}

fn parse_desktop(path: &Path) -> Option<(String, AppEntry)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let mut exec = None;
    let mut icon = None;
    let mut name = None;
    let mut nodisplay = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            if in_entry {
                break;
            }
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        match key.trim() {
            "Hidden" if value.eq_ignore_ascii_case("true") => return None,
            "Exec" => exec = Some(value.to_string()),
            "Icon" => icon = Some(value.to_string()),
            "Name" => name = Some(value.to_string()),
            "NoDisplay" => nodisplay = value.eq_ignore_ascii_case("true"),
            _ => {}
        }
    }
    let exe = exec_binary(&exec?).filter(|e| !e.is_empty())?;
    let found = AppEntry {
        icon: icon.filter(|i| !i.is_empty()),
        name: name.filter(|n| !n.is_empty()),
        rank: u8::from(!nodisplay) + 2 * u8::from(path.file_stem()?.to_str()? == exe),
    };
    if found.icon.is_none() && found.name.is_none() {
        return None;
    }
    Some((exe, found))
}

fn exec_binary(exec: &str) -> Option<String> {
    for token in exec.split_whitespace() {
        if token == "env" || token.contains('=') || token.starts_with('-') {
            continue;
        }
        let cleaned = token.trim_matches('"').trim_matches('\'');
        return Path::new(cleaned)
            .file_name()
            .map(|n| n.to_string_lossy().to_string());
    }
    None
}
