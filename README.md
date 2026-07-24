# WPS Converter

无状态、同步的办公文档转换服务，通过 FastAPI 调用 LibreOffice：

- `.wps` 转换为 `.docx`
- `.et` 转换为 `.xlsx`

调用方负责保存原件和转换件。本服务不连接数据库、对象存储或业务应用，也不保留任务文件。

## 接口

### `POST /api/v1/convert`

使用 `multipart/form-data` 上传单个 `file`，并在 `X-API-Key` 中携带密钥。服务根据源文件扩展名选择固定目标格式，不接受 Filter、目标格式或其他 LibreOffice 参数。

成功响应为文件流：

| 源文件 | 响应格式 | Content-Type |
| --- | --- | --- |
| `.wps` | `.docx` | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |
| `.et` | `.xlsx` | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` |

失败响应示例：

```json
{
  "code": "CONVERSION_FAILED",
  "message": "LibreOffice could not recognize or convert this document",
  "requestId": "3d0bfec8-d656-41d0-8226-bdaef18253f7"
}
```

所有响应包含服务生成的 `X-Request-ID`。并发已满时返回 `429` 和 `Retry-After: 1`。

### 健康检查

- `GET /health/live`：进程存活检查，不认证。
- `GET /health/ready`：检查 `soffice` 是否存在且可执行，不认证。

## 配置

| 环境变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `CONVERTER_API_KEY` | 是 | 无 | 转换接口密钥；空值会导致服务启动失败 |
| `MAX_FILE_SIZE_MB` | 否 | `10` | 单文件大小上限 |
| `MAX_CONCURRENCY` | 否 | `4` | 同时处理的任务数；超限立即拒绝 |
| `CONVERSION_TIMEOUT_SECONDS` | 否 | `120` | 单次转换超时 |
| `SOFFICE_PATH` | 否 | `soffice` | soffice 可执行文件名或路径 |
| `LOG_LEVEL` | 否 | `INFO` | Python 日志级别 |

所有数值配置必须是正整数。日志不会记录 API Key、文件内容或客户端文件名。

## 本地开发

需要 Python 3.13、[uv](https://docs.astral.sh/uv/) 和本机 LibreOffice：

```bash
uv sync --dev
export CONVERTER_API_KEY='replace-with-a-long-random-secret'
uv run python main.py
```

运行测试：

```bash
uv run pytest
```

## Docker 部署

镜像基于 Debian，安装 LibreOffice Writer、Calc、Noto CJK 和文泉驿中文字体，并以 UID/GID `10001` 的非 root 用户运行。

```bash
cp .env.example .env
# 修改 .env 中的 CONVERTER_API_KEY
docker compose config
docker compose up -d --build
docker compose ps
```

停止服务：

```bash
docker compose down
```

Compose 默认监听宿主机 `8000` 端口。可通过 `CONVERTER_PORT` 修改宿主机端口。容器使用只读根文件系统，任务目录位于受限的临时文件系统；如需处理接近上限的大文件或提高并发数，应同步评估并调整 `tmpfs` 容量。

直接构建和运行：

```bash
docker build -t wps-converter:local .
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m \
  -p 8000:8000 \
  -e CONVERTER_API_KEY='replace-with-a-long-random-secret' \
  wps-converter:local
```

## curl 调用

转换 WPS 文件：

```bash
curl --fail-with-body \
  -H 'X-API-Key: replace-with-a-long-random-secret' \
  -F 'file=@./示例文档.wps' \
  --output './示例文档.docx' \
  http://127.0.0.1:8000/api/v1/convert
```

转换 ET 文件：

```bash
curl --fail-with-body \
  -H 'X-API-Key: replace-with-a-long-random-secret' \
  -F 'file=@./数据.et' \
  --output './数据.xlsx' \
  http://127.0.0.1:8000/api/v1/convert
```

检查健康状态：

```bash
curl http://127.0.0.1:8000/health/live
curl http://127.0.0.1:8000/health/ready
```

## Java 17 调用示例

以下示例使用 JDK 自带的 `HttpClient`，上传和下载均基于文件 BodyPublisher/BodyHandler，不需要把整个文档读入 Java 堆：

```java
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.UUID;

public class ConvertExample {
    public static void main(String[] args) throws Exception {
        Path source = Path.of("示例文档.wps");
        Path target = Path.of("示例文档.docx");
        String boundary = "----JavaBoundary" + UUID.randomUUID();

        String prefix = "--" + boundary + "\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\""
                + source.getFileName() + "\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n";
        String suffix = "\r\n--" + boundary + "--\r\n";

        HttpRequest.BodyPublisher body = HttpRequest.BodyPublishers.concat(
                HttpRequest.BodyPublishers.ofByteArray(
                        prefix.getBytes(StandardCharsets.UTF_8)),
                HttpRequest.BodyPublishers.ofFile(source),
                HttpRequest.BodyPublishers.ofByteArray(
                        suffix.getBytes(StandardCharsets.UTF_8)));

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create("http://127.0.0.1:8000/api/v1/convert"))
                .header("X-API-Key", "replace-with-a-long-random-secret")
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(body)
                .build();

        HttpResponse<Path> response = HttpClient.newHttpClient().send(
                request, HttpResponse.BodyHandlers.ofFile(target));
        if (response.statusCode() != 200) {
            throw new IllegalStateException(
                    "Conversion failed, HTTP " + response.statusCode());
        }
        System.out.println("Saved to " + response.body());
    }
}
```

生产调用方还应设置连接/请求超时、限制重试次数，并在非 200 响应时将错误体保存到单独位置，避免把 JSON 错误覆盖为目标文档。

## 兼容性和安全边界

- 实际转换能力取决于镜像内 LibreOffice 对具体 WPS/ET 版本的识别能力。
- 加密或损坏的文件、含宏文件、特殊嵌入对象、罕见公式、缺失字体以及复杂排版可能转换失败或出现版式差异。
- 服务仅在 LibreOffice 成功退出且产物为结构有效的 DOCX/XLSX 时返回成功；不会复制原文件冒充转换结果。
- 服务不承诺支持所有 WPS Office 版本。上线前应使用业务侧脱敏样本对文字、表格、图片、页眉页脚、公式和分页效果进行回归。
- 客户端 MIME 类型不参与格式判断；服务只允许固定源扩展名和固定目标格式。原件应由调用方留存。
