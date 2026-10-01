use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{Request, StatusCode},
    response::Response,
    Router,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::{AppHandle, Emitter};
use tokio::sync::{oneshot, Semaphore};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    listening: bool,
    allow_lan: bool,
    host: Option<String>,
    port: Option<u16>,
    error: Option<serde_json::Value>,
}
impl Default for Status {
    fn default() -> Self {
        Self {
            listening: false,
            allow_lan: false,
            host: None,
            port: None,
            error: None,
        }
    }
}
struct Running {
    status: Status,
    stop: oneshot::Sender<()>,
    task: tauri::async_runtime::JoinHandle<()>,
}
#[derive(Default)]
pub struct ControlState {
    servers: Mutex<HashMap<String, Running>>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Reply>>>,
    sequence: AtomicU64,
}
// 客户端断开导致请求任务取消时，也必须释放等待回传的条目。
struct PendingRequest {
    shared: Arc<ControlState>,
    id: u64,
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        self.shared.pending.lock().unwrap().remove(&self.id);
    }
}
#[derive(Deserialize)]
pub struct Reply {
    status: u16,
    body: String,
    content_type: String,
}
#[derive(Clone, Serialize)]
pub struct BridgeRequest {
    id: u64,
    kind: String,
    method: String,
    path: String,
    body: String,
    accept: String,
    protocol: Option<String>,
}
#[derive(Clone)]
struct Endpoint {
    app: AppHandle,
    shared: Arc<ControlState>,
    kind: String,
    key: String,
    host: String,
    port: u16,
    permits: Arc<Semaphore>,
}

fn response(status: u16, message: &str) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(message.to_owned()))
        .unwrap()
}
fn key_matches(expected: &str, actual: &str) -> bool {
    expected.len() == actual.len()
        && expected
            .bytes()
            .zip(actual.bytes())
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            == 0
}

async fn handle(State(endpoint): State<Endpoint>, request: Request<Body>) -> Response {
    let Ok(_permit) = endpoint.permits.try_acquire() else {
        return response(429, "{\"error\":\"too many requests\"}");
    };
    let headers = request.headers();
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let allowed_hosts = [
        format!("127.0.0.1:{}", endpoint.port),
        format!("localhost:{}", endpoint.port),
        format!("{}:{}", endpoint.host, endpoint.port),
    ];
    if headers.contains_key("origin") || !allowed_hosts.iter().any(|value| value == host) {
        return response(403, "{\"error\":\"origin or host denied\"}");
    }
    let key_header = if endpoint.kind == "mcp" {
        "x-mcp-key"
    } else {
        "x-api-key"
    };
    if !key_matches(
        &endpoint.key,
        headers
            .get(key_header)
            .and_then(|v| v.to_str().ok())
            .unwrap_or(""),
    ) {
        return response(401, "{\"error\":\"invalid access key\"}");
    }
    let method = request.method().as_str().to_owned();
    let path = request.uri().path().to_owned();
    if endpoint.kind == "mcp" && (method != "POST" || path != "/mcp") {
        return response(405, "{\"error\":\"use POST /mcp\"}");
    }
    let accept = headers
        .get("accept")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json, text/event-stream")
        .to_owned();
    let protocol = headers
        .get("mcp-protocol-version")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let bytes =
        match tokio::time::timeout(Duration::from_secs(3), to_bytes(request.into_body(), 65536))
            .await
        {
            Ok(Ok(bytes)) => bytes,
            _ => return response(413, "{\"error\":\"body too large or incomplete\"}"),
        };
    let Ok(body) = String::from_utf8(bytes.to_vec()) else {
        return response(400, "{\"error\":\"invalid UTF-8\"}");
    };
    let id = endpoint.shared.sequence.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = oneshot::channel();
    endpoint.shared.pending.lock().unwrap().insert(id, tx);
    let _pending = PendingRequest {
        shared: endpoint.shared.clone(),
        id,
    };
    let event = BridgeRequest {
        id,
        kind: endpoint.kind,
        method,
        path,
        body,
        accept,
        protocol,
    };
    if endpoint
        .app
        .emit_to("main", "mobile-control-request", event)
        .is_err()
    {
        return response(503, "{\"error\":\"player unavailable\"}");
    }
    let result = tokio::time::timeout(Duration::from_secs(15), rx).await;
    match result {
        Ok(Ok(reply)) if reply.body.len() <= 1024 * 1024 => Response::builder()
            .status(StatusCode::from_u16(reply.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR))
            .header(
                "content-type",
                if reply.content_type == "text/event-stream" {
                    "text/event-stream"
                } else {
                    "application/json"
                },
            )
            .header("cache-control", "no-store")
            .body(Body::from(reply.body))
            .unwrap(),
        _ => response(503, "{\"error\":\"keep SPlayer in foreground\"}"),
    }
}

#[tauri::command]
pub fn control_reply(state: tauri::State<'_, Arc<ControlState>>, id: u64, reply: Reply) {
    if let Some(sender) = state.pending.lock().unwrap().remove(&id) {
        let _ = sender.send(reply);
    }
}
#[tauri::command]
pub fn control_status(state: tauri::State<'_, Arc<ControlState>>, kind: String) -> Status {
    state
        .servers
        .lock()
        .unwrap()
        .get(&kind)
        .map(|server| server.status.clone())
        .unwrap_or_default()
}
#[tauri::command]
pub async fn control_stop(
    state: tauri::State<'_, Arc<ControlState>>,
    kind: String,
) -> Result<(), String> {
    let previous = state.servers.lock().unwrap().remove(&kind);
    if let Some(server) = previous {
        let _ = server.stop.send(());
        let _ = server.task.await;
    }
    Ok(())
}

#[tauri::command]
pub async fn control_start(
    app: AppHandle,
    state: tauri::State<'_, Arc<ControlState>>,
    kind: String,
    port: u16,
    allow_lan: bool,
    key: String,
) -> Result<Status, String> {
    if !["mcp", "external"].contains(&kind.as_str())
        || port < 1024
        || key.len() < 32
        || key.len() > 128
    {
        return Err("控制服务配置无效".into());
    }
    let previous = state.servers.lock().unwrap().remove(&kind);
    if let Some(server) = previous {
        let _ = server.stop.send(());
        let _ = server.task.await;
    }
    let bind = if allow_lan { "0.0.0.0" } else { "127.0.0.1" };
    let listener = tokio::net::TcpListener::bind((bind, port))
        .await
        .map_err(|e| e.to_string())?;
    let host = if allow_lan {
        let socket = std::net::UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
        socket.connect("192.0.2.1:9").map_err(|e| e.to_string())?;
        socket
            .local_addr()
            .map_err(|e| e.to_string())?
            .ip()
            .to_string()
    } else {
        "127.0.0.1".into()
    };
    let status = Status {
        listening: true,
        allow_lan,
        host: Some(host.clone()),
        port: Some(port),
        error: None,
    };
    let endpoint = Endpoint {
        app,
        shared: state.inner().clone(),
        kind: kind.clone(),
        key,
        host,
        port,
        permits: Arc::new(Semaphore::new(8)),
    };
    let (stop, stopped) = oneshot::channel();
    let router = Router::new().fallback(handle).with_state(endpoint);
    let task = tauri::async_runtime::spawn(async move {
        let _ = axum::serve(listener, router)
            .with_graceful_shutdown(async {
                let _ = stopped.await;
            })
            .await;
    });
    state.servers.lock().unwrap().insert(
        kind,
        Running {
            status: status.clone(),
            stop,
            task,
        },
    );
    Ok(status)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keys_require_exact_match() {
        assert!(key_matches("secret", "secret"));
        assert!(!key_matches("secret", "secreT"));
        assert!(!key_matches("secret", ""));
    }
}
