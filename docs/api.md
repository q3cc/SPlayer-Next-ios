# 外部 API（HTTP）

SPlayer-Next 提供一个可选的本地 HTTP 接口，用于查询播放状态与控制播放。实时状态推送请使用 [WebSocket API](/socket)，接入 AI 应用请使用 [MCP 接口](/mcp)。

::: warning 默认关闭
外部 API **默认关闭**，需在设置的外部 API 区域中开启。服务默认仅绑定 `127.0.0.1`（本机可访问）。桌面端接口**不含鉴权**，移动端必须携带 `X-API-Key`；如需局域网访问，请显式开启「允许局域网访问」，并仅在可信网络中使用。
:::

AI 使用的 [MCP 接口](/mcp)拥有独立开关、端口与服务生命周期，不依赖此外部 API。

## 约定

### iOS / Android 的支持范围

在 **设置 → 网络与服务 → 外部 API** 开启服务后，点击「复制外部控制连接配置」获取实际地址和 `X-API-Key`。请保持应用在前台；后台不会维持控制服务。连接使用 HTTP，不要在不可信网络使用或映射到公网。浏览器跨站请求不受支持。

移动端支持 `GET /api/info`、`GET /api/status`、`GET /api/now-playing`，以及 `POST /api/play`、`pause`、`stop`、`next`、`prev`、`seek`、`volume`。进度参数为 `{ "positionMs": 30000 }`，音量为 `{ "volume": 0.5 }`。暂不提供 WebSocket、歌词和其他桌面专用端点。

以下完整端点表面向桌面端；移动端以以上范围为准。

- **基础路径**：`http://127.0.0.1:<port>/api`
- **默认端口**：`14558`（可在设置中修改）
- **数据格式**：请求与响应均为 JSON（`Content-Type: application/json`）
- **时间单位**：毫秒（ms）
- **成功响应**：控制类接口返回 `{ "ok": true }`
- **错误响应**：参数非法返回 `400`，响应体为 `{ "error": "<原因>" }`

## 端点总览

| 方法   | 路径               | 说明                   |
| ------ | ------------------ | ---------------------- |
| `GET`  | `/api/info`        | 应用与连接信息         |
| `GET`  | `/api/status`      | 播放状态               |
| `GET`  | `/api/volume`      | 当前音量               |
| `GET`  | `/api/now-playing` | 不含完整歌词的轻量快照 |
| `GET`  | `/api/lyrics`      | 当前曲目的完整解析歌词 |
| `POST` | `/api/play`        | 播放                   |
| `POST` | `/api/pause`       | 暂停                   |
| `POST` | `/api/stop`        | 停止                   |
| `POST` | `/api/next`        | 下一曲                 |
| `POST` | `/api/prev`        | 上一曲                 |
| `POST` | `/api/seek`        | 跳转到指定位置         |
| `POST` | `/api/volume`      | 设置音量               |

## 状态查询

### 获取应用信息

```
GET /api/info
```

返回应用名称、版本与当前 WebSocket 连接数。

**响应**

```json
{ "name": "SPlayer-Next", "version": "1.0.0", "wsClients": 0 }
```

### 获取播放状态

```
GET /api/status
```

**响应**

```json
{
  "state": "playing",
  "position": 12000,
  "duration": 240000,
  "volume": 1,
  "isFinished": false
}
```

| 字段         | 类型      | 说明                              |
| ------------ | --------- | --------------------------------- |
| `state`      | `string`  | 播放状态（如 `playing`/`paused`） |
| `position`   | `number`  | 当前播放位置（毫秒）              |
| `duration`   | `number`  | 总时长（毫秒）                    |
| `volume`     | `number`  | 音量（0 ~ 1）                     |
| `isFinished` | `boolean` | 当前曲目是否已播放结束            |

### 获取音量

```
GET /api/volume
```

**响应**

```json
{ "volume": 1 }
```

### 获取当前播放快照

```
GET /api/now-playing
```

返回适合频繁轮询的轻量快照，不包含完整歌词正文。`lyricAvailable` 表示当前是否有
歌词，`lyricLineCount` 表示歌词行数。需要歌词时单独请求 `/api/lyrics`。

### 获取当前歌词

```
GET /api/lyrics
```

返回当前曲目的完整解析歌词、歌词来源和偏移。`lyric` 保持结构化 JSON 数组，避免将
JSON 再编码成字符串所产生的双重转义和额外解析；服务在网络传输时会输出紧凑 JSON。

## 播放控制

### 播放

```
POST /api/play
```

**响应**：`{ "ok": true }`

### 暂停

```
POST /api/pause
```

**响应**：`{ "ok": true }`

### 停止

```
POST /api/stop
```

**响应**：`{ "ok": true }`

### 下一曲

```
POST /api/next
```

**响应**：`{ "ok": true }`

### 上一曲

```
POST /api/prev
```

**响应**：`{ "ok": true }`

### 跳转

```
POST /api/seek
```

**请求体**

| 字段         | 类型     | 必填 | 说明                  |
| ------------ | -------- | ---- | --------------------- |
| `positionMs` | `number` | ✅   | 目标位置（毫秒，≥ 0） |

```json
{ "positionMs": 60000 }
```

**响应**：`{ "ok": true }`；参数非法返回 `400`。

### 设置音量

```
POST /api/volume
```

**请求体**

| 字段     | 类型     | 必填 | 说明          |
| -------- | -------- | ---- | ------------- |
| `volume` | `number` | ✅   | 音量（0 ~ 1） |

```json
{ "volume": 0.5 }
```

**响应**：`{ "ok": true }`；参数非法返回 `400`。

## 示例

```bash
# 查询播放状态
curl http://127.0.0.1:14558/api/status

# 播放 / 暂停 / 下一曲
curl -X POST http://127.0.0.1:14558/api/play
curl -X POST http://127.0.0.1:14558/api/pause
curl -X POST http://127.0.0.1:14558/api/next

# 跳转到 1 分钟处
curl -X POST http://127.0.0.1:14558/api/seek \
  -H "Content-Type: application/json" \
  -d '{ "positionMs": 60000 }'

# 设置音量为 50%
curl -X POST http://127.0.0.1:14558/api/volume \
  -H "Content-Type: application/json" \
  -d '{ "volume": 0.5 }'
```
