use ferrous_opencc::{config::BuiltinConfig, OpenCC};
use std::sync::Mutex;

// 只保留当前转换模式，切换设置时释放上一份字典。
static CONVERTER: Mutex<Option<(String, OpenCC)>> = Mutex::new(None);

fn parse_builtin_config(config_name: &str) -> Option<BuiltinConfig> {
    match config_name.to_ascii_lowercase().as_str() {
        "s2t" => Some(BuiltinConfig::S2t),
        "t2s" => Some(BuiltinConfig::T2s),
        "s2tw" => Some(BuiltinConfig::S2tw),
        "tw2s" => Some(BuiltinConfig::Tw2s),
        "s2hk" => Some(BuiltinConfig::S2hk),
        "hk2s" => Some(BuiltinConfig::Hk2s),
        "s2twp" => Some(BuiltinConfig::S2twp),
        "tw2sp" => Some(BuiltinConfig::Tw2sp),
        "t2tw" => Some(BuiltinConfig::T2tw),
        "tw2t" => Some(BuiltinConfig::Tw2t),
        "t2hk" => Some(BuiltinConfig::T2hk),
        "hk2t" => Some(BuiltinConfig::Hk2t),
        "jp2t" => Some(BuiltinConfig::Jp2t),
        "t2jp" => Some(BuiltinConfig::T2jp),
        _ => None,
    }
}

#[tauri::command]
pub async fn convert_lyrics(texts: Vec<String>, config: String) -> Result<Vec<String>, String> {
    tauri::async_runtime::spawn_blocking(move || convert(texts, config))
        .await
        .map_err(|error| error.to_string())?
}

fn convert(texts: Vec<String>, config: String) -> Result<Vec<String>, String> {
    if config == "none" || texts.is_empty() {
        return Ok(texts);
    }
    let builtin = parse_builtin_config(&config).ok_or("不支持的歌词转换方式")?;
    let mut cache = CONVERTER.lock().map_err(|error| error.to_string())?;
    if cache.as_ref().map(|entry| &entry.0) != Some(&config) {
        *cache = None;
        *cache = Some((
            config,
            OpenCC::from_config(builtin).map_err(|error| error.to_string())?,
        ));
    }
    let converter = &cache.as_ref().unwrap().1;
    Ok(texts.iter().map(|text| converter.convert(text)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn converts_and_changes_modes() {
        assert_eq!(
            convert(vec!["音乐与歌词".into()], "s2t".into()).unwrap(),
            vec!["音樂與歌詞"]
        );
        assert_eq!(
            convert(vec!["音樂與歌詞".into()], "t2s".into()).unwrap(),
            vec!["音乐与歌词"]
        );
        assert!(convert(vec!["音乐".into()], "invalid".into()).is_err());
    }
    #[test]
    fn keeps_batch_order_and_empty_lines() {
        assert_eq!(
            convert(vec!["".into(), "歌词".into()], "s2t".into()).unwrap(),
            vec!["", "歌詞"]
        );
    }
}
