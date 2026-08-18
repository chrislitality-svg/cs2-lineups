# cs2sync — 战术沙盘的云同步服务

部署在 `ops:/opt/cs2sync/server.py`，systemd 单元 `cs2sync.service`，
监听 `127.0.0.1:8094`，由 nginx 反代到 `/cs2/sync/`。

这份是生产文件的副本。**改完要 `scp` 回去并 `systemctl restart cs2sync`**，
它不像前端那样能靠刷新生效。

## 数据布局

```
/opt/cs2sync/
  meta.json          道具 / 点位 / 地名 / 出生点 / 标签，整包读写
  imgs/<key>         单张图的二进制（key = "<道具id>_<stand|aim|effect>"）
  imgs-index.json    {key: {sz, sha, ts}}，约 17KB
```

## 为什么是一图一文件

2026-08-18 之前所有图片 base64 塞在一个 `imgs.json` 里，涨到 80MB。
后果是改一张图要整包重传、开一次页要整包下载，而 nginx 对 `/cs2/sync/`
的 `client_max_body_size` 只有 100m —— 已经快撑爆了。
当时的权宜之计是用 `cs2_imgs_ok` 标记「核对过就再也不查」，
等于放弃了多设备一致性。

改成一图一文件后，客户端每次只拉 17KB 索引比对，只传差异，且走二进制
（省掉 base64 的 33% 膨胀）。稳态开页 3 个请求 67KB，而且是真的把
255 张全核对了一遍。

## 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 探针，返回 `{"ok":true}` |
| GET/PUT | `/` | meta |
| GET | `/imgs/index` | 图片索引 |
| GET/PUT/DELETE | `/imgs/<key>` | 单张图，二进制 body |
| GET/PUT | `/imgs` | 旧整包端点，已停用返回 410 |

`<key>` 走白名单 `^[A-Za-z0-9_.-]{1,120}$`，挡路径穿越；单图上限 12MB。

## 迁移与备份

迁移前的整包快照留在 `imgs.json.bak-preincr-*`，255 张逐字节校验过才切的。
真要回滚：把 `server.py.bak-*` 换回去、重启，旧客户端就还能用整包端点。
