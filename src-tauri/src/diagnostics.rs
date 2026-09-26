use std::{
    fs::{File, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
#[cfg(target_os = "android")]
use tauri::Manager;

struct SessionLog {
    file: File,
    path: PathBuf,
    #[cfg(target_os = "ios")]
    stdout: File,
    #[cfg(target_os = "ios")]
    stderr: File,
}

static SESSION_LOG: Mutex<Option<SessionLog>> = Mutex::new(None);
static STARTED_AT: OnceLock<chrono::DateTime<chrono::Local>> = OnceLock::new();

/// 只保存启动时间；用户开启日志前不创建目录或文件。
pub fn init() -> Result<(), String> {
    STARTED_AT.get_or_init(chrono::Local::now);
    Ok(())
}

#[tauri::command]
pub fn set_diagnostic_logging(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    let mut state = SESSION_LOG.lock().map_err(|e| e.to_string())?;
    if !enabled {
        if let Some(log) = state.as_mut() {
            log.file.flush().map_err(|e| e.to_string())?;
            #[cfg(target_os = "ios")]
            {
                use std::os::fd::AsRawFd;
                // 恢复系统输出目标，避免原生插件在开关关闭后继续写入文件。
                unsafe {
                    libc::fflush(std::ptr::null_mut());
                    let out = libc::dup2(log.stdout.as_raw_fd(), libc::STDOUT_FILENO);
                    let err = libc::dup2(log.stderr.as_raw_fd(), libc::STDERR_FILENO);
                    if out == -1 || err == -1 {
                        return Err(std::io::Error::last_os_error().to_string());
                    }
                }
            }
        }
        *state = None;
        return Ok(());
    }
    if state.is_some() {
        return Ok(());
    }
    #[cfg(target_os = "ios")]
    let directory = PathBuf::from(std::env::var_os("HOME").ok_or("iOS sandbox HOME missing")?)
        .join("Documents/logs");
    #[cfg(target_os = "android")]
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("logs");
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let directory = std::env::temp_dir().join("splayer-logs");
    #[cfg(not(target_os = "android"))]
    let _ = app;
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let started = STARTED_AT.get_or_init(chrono::Local::now);
    let path = directory.join(format!("{}.log", started.format("%Y-%m-%d_%H-%M-%S%.3f%z")));
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| e.to_string())?;
    writeln!(
        file,
        "{} [native] logging-enabled version={} started={}",
        chrono::Local::now().to_rfc3339(),
        env!("CARGO_PKG_VERSION"),
        started.to_rfc3339()
    )
    .map_err(|e| e.to_string())?;

    #[cfg(target_os = "ios")]
    let (stdout, stderr) = {
        use std::os::fd::{AsRawFd, FromRawFd};
        // 保存原文件描述符，并在任一重定向失败时恢复已修改的目标。
        unsafe {
            libc::fflush(std::ptr::null_mut());
            let out = libc::dup(libc::STDOUT_FILENO);
            if out == -1 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let stdout = File::from_raw_fd(out);
            let err = libc::dup(libc::STDERR_FILENO);
            if err == -1 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let stderr = File::from_raw_fd(err);
            if libc::dup2(file.as_raw_fd(), libc::STDOUT_FILENO) == -1
                || libc::dup2(file.as_raw_fd(), libc::STDERR_FILENO) == -1
            {
                let error = std::io::Error::last_os_error().to_string();
                libc::dup2(stdout.as_raw_fd(), libc::STDOUT_FILENO);
                libc::dup2(stderr.as_raw_fd(), libc::STDERR_FILENO);
                return Err(error);
            }
            (stdout, stderr)
        }
    };
    *state = Some(SessionLog {
        file,
        path,
        #[cfg(target_os = "ios")]
        stdout,
        #[cfg(target_os = "ios")]
        stderr,
    });
    Ok(())
}

#[tauri::command]
pub fn append_diagnostic_log(entries: Vec<String>) -> Result<(), String> {
    if entries.len() > 32 || entries.iter().any(|line| line.len() > 65536) {
        return Err("diagnostic batch too large".into());
    }
    let mut state = SESSION_LOG.lock().map_err(|e| e.to_string())?;
    // 关闭开关时可能仍有一批 IPC 在途，直接丢弃，不重新创建文件。
    let Some(log) = state.as_mut() else {
        return Ok(());
    };
    for entry in entries {
        writeln!(log.file, "{entry}").map_err(|e| e.to_string())?;
    }
    log.file.flush().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn diagnostic_log_path() -> Result<String, String> {
    SESSION_LOG
        .lock()
        .map_err(|e| e.to_string())?
        .as_ref()
        .map(|log| log.path.to_string_lossy().into_owned())
        .ok_or_else(|| "diagnostic logging disabled".into())
}

#[cfg(target_os = "android")]
#[tauri::command]
pub fn prepare_diagnostic_log_share(app: tauri::AppHandle) -> Result<String, String> {
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("logs");
    let active = {
        let mut state = SESSION_LOG.lock().map_err(|e| e.to_string())?;
        if let Some(log) = state.as_mut() {
            log.file.flush().map_err(|e| e.to_string())?;
        }
        state.as_ref().map(|log| log.path.clone())
    };
    let source = match active {
        Some(path) => path,
        None => std::fs::read_dir(&directory)
            .map_err(|e| e.to_string())?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "log"))
            .max()
            .ok_or("没有可分享的日志")?,
    };
    let destination = app
        .path()
        .app_cache_dir()
        .map_err(|e| e.to_string())?
        .join("diagnostics");
    std::fs::create_dir_all(&destination).map_err(|e| e.to_string())?;
    let target = destination.join(source.file_name().ok_or("日志文件名无效")?);
    std::fs::copy(source, &target).map_err(|e| e.to_string())?;
    Ok(target.to_string_lossy().into_owned())
}
