# WPS Converter

无状态的办公文档转换服务。服务通过 HTTP 接收文件，在 Docker 容器内调用
LibreOffice（Office 格式）或 OFDRW（OFD 格式）完成转换，然后直接返回转换后的
文件。

LibreOffice、毕昇 JDK 运行时和 OFD 转换器都已经安装在镜像内，部署服务器只需要
安装 Docker，不需要单独安装这些运行时。

## 支持格式

| 源文件 | 目标文件 |
| --- | --- |
| `.doc`（旧版 Word） | `.docx` |
| `.wps` | `.docx` |
| `.xls`（旧版 Excel） | `.xlsx` |
| `.et` | `.xlsx` |
| `.ofd`（版式文档） | `.pdf` |

服务根据上传文件名的扩展名判断格式，不使用客户端 MIME 类型，也不接受调用方
传入的 LibreOffice 参数。调用方应自行保存原文件和转换结果；本服务不连接数据库、
对象存储或业务系统，也不持久化任务文件。

## 快速部署

### 1. 准备代码

将当前代码复制或发布到服务器，例如：

```bash
git clone <repository-url> /opt/wps-converter
cd /opt/wps-converter
```

如果使用当前 `.doc` 转换版本，请确保服务器上的代码包含该版本改动。

### 2. 配置环境变量

```bash
cp .env.example .env
openssl rand -hex 32
```

将生成的随机字符串填入 `.env` 的 `CONVERTER_API_KEY`：

```dotenv
CONVERTER_API_KEY=replace-with-a-long-random-secret
CONVERTER_PORT=8028
MAX_FILE_SIZE_MB=50
MAX_CONCURRENCY=4
CONVERSION_TIMEOUT_SECONDS=120
SOFFICE_PATH=/usr/bin/soffice
OFD_CONVERTER_PATH=ofd2pdf
LOG_LEVEL=INFO
```

不要把 `.env` 提交到 Git，也不要在日志或接口响应中暴露 API Key。

### 3. 构建并启动

```bash
docker compose config
docker compose up -d --build
docker compose ps
```

构建完成后，镜像中会包含以下运行时组件：

- LibreOffice Writer：处理 `.doc`、`.wps` 到 `.docx`
- LibreOffice Calc：处理 `.xls`、`.et` 到 `.xlsx`
- 毕昇 JDK 21 运行时和 OFDRW：处理 `.ofd` 到 `.pdf`
- Noto CJK、文泉驿、文鼎和朱雀仿宋字体：减少中文字体缺失导致的排版问题

查看日志：

```bash
docker compose logs -f converter
```

停止服务：

```bash
docker compose down
```

首次构建或依赖、系统软件包层发生变化时，需要访问 Debian、PyPI 和 Docker 基础镜像。
如果服务器无法访问这些源，可以在有网络的准备阶段完成首次构建，或准备对应的本地
镜像和依赖缓存。需要在无互联网环境中频繁更新代码时，请参阅
[`docs/offline-deployment.md`](docs/offline-deployment.md)。

## Jenkins 部署

仓库提供 `deploy/Jenkinsfile`、`deploy/deploy.sh` 和
[`deploy/jenkins-deployment.md`](deploy/jenkins-deployment.md)。流水线在 Jenkins
机构建镜像，直传目标机，先在隔离容器内做预检，再替换容器并执行
`/health/ready` 健康门禁；失败自动回滚上一版本。当前默认目标机为测试转换机
`CHANGE_ME_WPS_TARGET_IP:8028`（`/data/wps-converter`），与测试后端 `WPS_CONVERTER_URL`
一致。首次配置、目标机 `.env`、Jenkins job 和回滚命令见部署文档。

## 健康检查

```bash
curl http://127.0.0.1:8028/health/live
curl http://127.0.0.1:8028/health/ready
```

正常响应：

```json
{"status":"ready","soffice":true,"ofdConverter":true}
```

`/health/live` 只检查服务进程；`/health/ready` 还会检查容器内的 `soffice`
和 `ofd2pdf` 是否存在且可执行。

## 接口调用

接口地址：

```text
POST /api/v1/convert
Content-Type: multipart/form-data
Header: X-API-Key
Field: file
```

请求必须包含且只能包含一个名为 `file` 的文件字段。

### `.doc` 转 `.docx`

```bash
curl --fail-with-body \
  -H "X-API-Key: ${CONVERTER_API_KEY}" \
  -F 'file=@./测试文档.doc' \
  --output ./测试文档.docx \
  http://127.0.0.1:8028/api/v1/convert
```

### `.wps` 转 `.docx`

```bash
curl --fail-with-body \
  -H "X-API-Key: ${CONVERTER_API_KEY}" \
  -F 'file=@./示例文档.wps' \
  --output ./示例文档.docx \
  http://127.0.0.1:8028/api/v1/convert
```

### `.et` 转 `.xlsx`

```bash
curl --fail-with-body \
  -H "X-API-Key: ${CONVERTER_API_KEY}" \
  -F 'file=@./数据.et' \
  --output ./数据.xlsx \
  http://127.0.0.1:8028/api/v1/convert
```

### `.xls` 转 `.xlsx`

```bash
curl --fail-with-body \
  -H "X-API-Key: ${CONVERTER_API_KEY}" \
  -F 'file=@./旧版数据.xls' \
  --output ./旧版数据.xlsx \
  http://127.0.0.1:8028/api/v1/convert
```

### `.ofd` 转 `.pdf`

```bash
curl --fail-with-body \
  -H "X-API-Key: ${CONVERTER_API_KEY}" \
  -F 'file=@./对外投资管理办法.ofd' \
  --output ./对外投资管理办法.pdf \
  http://127.0.0.1:8028/api/v1/convert
```

成功响应是文件流，并包含正确的 `Content-Type` 和下载文件名。所有响应都包含
服务生成的 `X-Request-ID`。

常见错误：

| HTTP 状态码 | 错误码 | 含义 |
| --- | --- | --- |
| `401` | `AUTH_FAILED` | `X-API-Key` 缺失或错误 |
| `413` | `FILE_TOO_LARGE` | 文件超过大小限制 |
| `415` | `UNSUPPORTED_FORMAT` | 文件扩展名不是 `.doc`、`.wps`、`.xls`、`.et` 或 `.ofd` |
| `429` | `CONCURRENCY_LIMIT` | 当前并发数已达到上限 |
| `502` | `CONVERSION_FAILED` | 转换引擎无法启动或转换失败 |

错误响应格式：

```json
{
  "code": "CONVERSION_FAILED",
  "message": "LibreOffice could not recognize or convert this document",
  "requestId": "3d0bfec8-d656-41d0-8226-bdaef18253f7"
}
```

## 配置项

| 环境变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `CONVERTER_API_KEY` | 是 | 无 | 转换接口认证密钥 |
| `CONVERTER_PORT` | Compose 必填 | 无 | 宿主机端口，容器端口固定为 `8000` |
| `MAX_FILE_SIZE_MB` | 否 | `50` | 单个文件大小上限 |
| `MAX_CONCURRENCY` | 否 | `4` | 同时执行的转换任务数 |
| `CONVERSION_TIMEOUT_SECONDS` | 否 | `120` | 单个转换任务超时时间 |
| `SOFFICE_PATH` | 否 | `soffice` | LibreOffice 可执行文件路径 |
| `OFD_CONVERTER_PATH` | 否 | `ofd2pdf` | OFD 转 PDF 可执行文件路径 |
| `LOG_LEVEL` | 否 | `INFO` | 日志级别 |

所有数值配置必须是正整数。服务不会记录 API Key、文件内容或客户端文件名。

Compose 默认使用只读根文件系统，并将临时文件放在大小为 512 MB 的 tmpfs 中。
OFD 转换使用毕昇 JRE 单进程运行，默认最大堆为 512 MB。如果提高文件大小上限、
并发数或单文件页数，应同步评估临时空间和内存。

## 本地开发

本地开发需要 Python 3.13、`uv` 和本机 LibreOffice。只调试 Office 转换时可以把
`OFD_CONVERTER_PATH` 指向任意可执行文件；调试 OFD 转换需要另行构建
`ofd-converter` 并准备毕昇 JDK 或兼容的 JDK 21：

```bash
uv sync --dev
export CONVERTER_API_KEY='replace-with-a-long-random-secret'
export SOFFICE_PATH=/usr/bin/soffice
export OFD_CONVERTER_PATH=/path/to/ofd2pdf
uv run python main.py
```

`ofd2pdf` 的构建方式：

```bash
cd ofd-converter
mvn -q -DskipTests package
java -Djava.awt.headless=true -jar target/ofd2pdf.jar input.ofd output.pdf
```

运行测试：

```bash
uv run python -m pytest
uv run python -m compileall -q main.py src tests scripts
```

## 真实样本测试

将脱敏的真实 `.doc`、`.wps`、`.xls`、`.et` 或 `.ofd` 文件放入被 Git 忽略的
`tests/docs/` 目录，然后运行 Docker 集成测试：

```bash
uv run python scripts/test_real_samples.py
```

脚本会构建生产镜像、启动临时容器、调用 HTTP 接口、检查返回的 OOXML 结构，
最后自动删除测试容器和转换产物。

复用已有镜像：

```bash
uv run python scripts/test_real_samples.py \
  --skip-build \
  --image wps-converter:local
```

## 兼容性说明

- `.doc` 使用旧版 Word 格式，复杂排版、页眉页脚、嵌入对象、宏、特殊字体等内容
  可能出现版式差异。
- `.ofd` 是固定版式文档，转换为 PDF 属于有损迁移：字体替换、复杂矢量图形、
  电子签章与印章可能失真，加密文档会直接转换失败。该能力面向知识库解析和问答，
  不用于还原可编辑文档。
- 部分 WPS 生成的 OFD 会用重叠描边模拟粗体，PDF 文本层可能在标题或页眉出现重复
  字符；正文提取不受影响，建议用业务样本回归检索和问答效果。
- OFD 未内嵌字体时会嵌入镜像内的替代字体，PDF 体积可能明显增大；调用方仍需按
  自身输出大小上限处理转换结果。
- 加密、损坏或对应转换引擎无法识别的文件会转换失败。
- `.doc` 和 `.xls` 的输出目标分别是标准 OOXML `.docx` 和 `.xlsx`，`.ofd` 的输出
  目标是包含至少一页且可解析的 PDF；服务只有在输出结构有效时才返回成功。
- 上线前应使用业务侧脱敏样本回归文字、图片、表格、分页、公式和字体效果。

## 公文字体

镜像按 GB/T 9704-2012 常见字体名称准备了开源替代字体：

| 公文标准字体 | 镜像内替代字体 |
| --- | --- |
| 宋体 | AR PL SungtiL GB |
| 仿宋 / 仿宋_GB2312 | 朱雀仿宋（Zhuque Fangsong） |
| 楷体 / 楷体_GB2312 | AR PL KaitiM GB |
| 黑体 | 文泉驿正黑 |
| 方正小标宋简体 | Noto Serif CJK SC |

OFD 内嵌字体始终优先使用，上述字体只在内嵌字体缺失时兜底。方正小标宋、中易
宋体等商用字体不随镜像分发，如生产环境需要严格还原原字体，应将已授权的字体文件
挂载到 `/usr/share/fonts/truetype/gongwen/` 并执行 `fc-cache -f`；OFDRW 会按
`simsun`、`simhei`、`simkai`、`simfang` 等文件名匹配系统字体。

## 生产建议

- 使用 Nginx、Ingress 或 API 网关提供 HTTPS，并限制请求体大小。
- 不要将转换服务直接暴露到公网；调用方与转换服务尽量使用内网通信。
- 调用方应设置连接和请求超时，并限制重试次数。
- 调用方负责保存原文件和转换结果，服务本身不提供持久化存储。
