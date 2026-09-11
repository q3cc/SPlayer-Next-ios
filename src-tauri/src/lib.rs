mod diagnostics;

fn record_boot_stage(stage: &str) {
    eprintln!("[splayer-boot] {stage}");
    // 冒烟进程需要无网络的启动标记；正式 IPA 不启用此特性，也不默认写日志。
    #[cfg(feature = "startup-smoke")]
    {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(std::env::temp_dir().join("splayer-boot.log"))
        {
            let _ = writeln!(file, "{stage}");
        }
    }
}

#[tauri::command]
fn report_boot_stage(stage: String) {
    record_boot_stage(&stage);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if let Err(error) = diagnostics::init() {
        eprintln!("[diagnostics] initialization failed: {error}");
    }
    record_boot_stage("native-entry");

    tauri::Builder::default()
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_ipa_update::init())
        .plugin(tauri_plugin_lyric_pip::init())
        .plugin(tauri_plugin_native_audio::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|_| {
            record_boot_stage("tauri-setup");
            // 音频会话由原生播放器在播放前统一配置，避免启动线程覆盖长音频路由策略。
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            report_boot_stage,
            diagnostics::append_diagnostic_log,
            diagnostics::set_diagnostic_logging,
            diagnostics::diagnostic_log_path
        ])
        .run(tauri::generate_context!())
        .expect("error while running SPlayer Next mobile");
}
