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

#[cfg(target_os = "ios")]
fn configure_ios_audio_session() {
    use objc2_avf_audio::{AVAudioSession, AVAudioSessionCategoryPlayback};

    // SAFETY: AVAudioSession 是 iOS 主进程内的线程安全单例；这里只在应用启动时配置一次。
    unsafe {
        let session = AVAudioSession::sharedInstance();
        let Some(category) = AVAudioSessionCategoryPlayback else {
            eprintln!("AVAudioSessionCategoryPlayback is unavailable");
            return;
        };
        if let Err(error) = session.setCategory_error(category) {
            eprintln!("failed to set iOS audio session category: {error}");
            return;
        }
        if let Err(error) = session.setActive_error(true) {
            eprintln!("failed to activate iOS audio session: {error}");
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
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .setup(|_| {
            record_boot_stage("tauri-setup");
            #[cfg(target_os = "ios")]
            std::thread::spawn(|| {
                record_boot_stage("audio-session-start");
                configure_ios_audio_session();
                record_boot_stage("audio-session-ready");
            });
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
