
## PS5 推送暂停/恢复：务必对照原版语义

原版 `pkg-sender` 的 `ResumeRow` 注释是权威依据：
"resume a stopped row **WITHOUT a new push**: the same URL is served again
(**counter kept**), so the console continues from its last byte"。

因此 PS5 pkg 行的恢复**只能**：
- `unrevoke(id)` + 用同一 id 重新注册 `RangeSource`
- **绝不** `resetServed(id)`（会清零进度，主机从头下载）
- **绝不** 把 `state` 改回 `.queued` 或重新入 `runQueue`（会导致二次推送）
- 保持 `state == .sending`

`/api/pull/pause`（`ConsoleClient.PullPauseAsync`）**只服务 copying / pull 镜像行**，
不要拿它当 pkg 推送的暂停信号。原版 `TransferManager.Pause()` 是 PC 端
`ManualResetEventSlim` 本地阻塞，连接与进度完全不动。
