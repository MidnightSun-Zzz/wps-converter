FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        fontconfig \
        fonts-noto-cjk \
        fonts-wqy-zenhei \
        libreoffice-calc \
        libreoffice-writer \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 converter \
    && useradd \
        --uid 10001 \
        --gid converter \
        --create-home \
        --home-dir /home/converter \
        --shell /usr/sbin/nologin \
        converter

WORKDIR /app

COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple .

USER converter:converter

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/ready', timeout=3)"]

CMD ["uvicorn", "wps_converter.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]
