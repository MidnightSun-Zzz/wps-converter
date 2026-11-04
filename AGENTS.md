# Repository Guidelines

跨仓库关系与 Git 授权边界见 `../AGENTS.md`；部署或运行配置任务再查 `README.md`。

## 项目与源码导航

Python 3.13 / FastAPI 无状态文档转换服务，调用 LibreOffice 将 `.doc`、`.wps` 转为 `.docx`，将 `.xls`、`.et` 转为 `.xlsx`；调用 OFDRW（毕昇 JDK）将 `.ofd` 转为 `.pdf`。

- `main.py`：uvicorn 启动入口。
- `src/wps_converter/app.py`、`multipart.py`：HTTP 请求和上传处理。
- `src/wps_converter/converter.py`：转换执行及临时文件处理；`config.py`、`errors.py`：配置与错误定义。
- `ofd-converter/`：基于 OFDRW 的 OFD 转 PDF Java CLI；`docker/`：`ofd2pdf` 包装脚本和公文字体映射。
- `tests/`：pytest 测试，`tests/fixtures/fake_soffice.py`、`fake_ofd2pdf.py` 用于模拟转换器；真实样本检查见 `scripts/test_real_samples.py`。
- 依赖与工具配置以 `pyproject.toml` 为准；沿用现有目录和测试体系，不为未来需求新增分层。

## 开发与验证

- 依赖缺失或锁文件变化时执行 `uv sync`，不在每次任务前重复安装。
- 按需用 `uv run python main.py` 启动服务；局部改动运行 `uv run pytest tests/test_app.py` 或 `uv run pytest tests/test_converter.py` 等相关用例。
- 仅转换行为或 LibreOffice 集成变化需要真实样本验证；缺少对应环境时说明边界，不自动部署或修改共享服务。
- 缺少关键覆盖时补最小回归测试；通过后停止。纯文档修改只检查内容和 `git diff --check`，不要求启动、构建或新增测试工具。
- 使用临时目录处理测试输出，不提交生成文档、缓存、`.venv/` 或含敏感信息的样本。

## 业务与安全边界

- 服务不持久化业务文件或任务，不连接平台数据库或对象存储；调用方负责保存原件和转换结果。
- 保留鉴权、格式及大小校验、并发限制、超时和失败清理；不允许调用方传入任意 LibreOffice 参数。
- 密钥通过运行时配置注入，不写入代码、日志或 Git。
- 接口、支持格式、认证或错误语义变化时检查 Java 调用方兼容性，仅更新受影响实现与文档。

## 代码与交付

沿用 PEP 8、四空格缩进和现有类型标注惯例。提交遵循全局 Conventional Commits 与授权规则；说明实际改动、相关验证及未验证边界，不附带无关重构。
