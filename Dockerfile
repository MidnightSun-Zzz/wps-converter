# syntax=docker/dockerfile:1

FROM python:3.13-slim-bookworm AS uv

RUN pip install --no-cache-dir uv==0.9.12

# Build the OFD adapter with BiSheng JDK so no non-domestic JDK is used by the build.
FROM python:3.13-slim-bookworm AS ofd-build

ARG TARGETARCH
ARG BISHENG_JDK_VERSION=21.0.12-b15
ARG MAVEN_VERSION=3.9.11

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
        amd64) jdk_arch=x64; jdk_sha=4531a4a33d51ae3617fd05a6b84dc393554fc22b56d0fa76b0aab20b9aa305ae ;; \
        arm64) jdk_arch=aarch64; jdk_sha=c4c3babd4b32f21de909c64d41e2296ac41d4da2397dab9982db10a2be27cd27 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/bisheng-jdk.tar.gz \
        "https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/bisheng-jdk-${BISHENG_JDK_VERSION}-linux-${jdk_arch}.tar.gz" \
    && echo "${jdk_sha}  /tmp/bisheng-jdk.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/bisheng-jdk \
    && tar -xzf /tmp/bisheng-jdk.tar.gz -C /opt/bisheng-jdk --strip-components=1 \
    && rm /tmp/bisheng-jdk.tar.gz

ENV JAVA_HOME=/opt/bisheng-jdk \
    PATH="/opt/bisheng-jdk/bin:${PATH}"

RUN curl -fsSL -o /tmp/apache-maven.tar.gz \
        "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    && echo "bcfe4fe305c962ace56ac7b5fc7a08b87d5abd8b7e89027ab251069faebee516b0ded8961445d6d91ec1985dfe30f8153268843c89aa392733d1a3ec956c9978  /tmp/apache-maven.tar.gz" | sha512sum -c - \
    && mkdir -p /opt/maven \
    && tar -xzf /tmp/apache-maven.tar.gz -C /opt/maven --strip-components=1 \
    && rm /tmp/apache-maven.tar.gz \
    && ln -s /opt/maven/bin/mvn /usr/local/bin/mvn

WORKDIR /build

COPY ofd-converter/pom.xml ./pom.xml
COPY ofd-converter/src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -q -DskipTests package

FROM python:3.13-slim-bookworm

ARG TARGETARCH
ARG BISHENG_JRE_VERSION=21.0.12-b15
ARG ZHUQUE_FANGSONG_VERSION=0.212

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates \
        curl \
        fontconfig \
        fonts-arphic-gbsn00lp \
        fonts-arphic-gkai00mp \
        fonts-noto-cjk \
        fonts-wqy-zenhei \
        libreoffice-calc \
        libreoffice-writer \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# BiSheng JRE 21 is the runtime component of BiSheng JDK 21.
RUN case "${TARGETARCH}" in \
        amd64) jre_arch=x64; jre_sha=8ea368185d1c193adef89b89c09e324c8f156d3a307e7e4764f536b1c8e198b1 ;; \
        arm64) jre_arch=aarch64; jre_sha=c687464b249ac48322242a7de7b192e13850b5d670951109745156189c3d2eca ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/bisheng-jre.tar.gz \
        "https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/bisheng-jre-${BISHENG_JRE_VERSION}-linux-${jre_arch}.tar.gz" \
    && echo "${jre_sha}  /tmp/bisheng-jre.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/bisheng-jre \
    && tar -xzf /tmp/bisheng-jre.tar.gz -C /opt/bisheng-jre --strip-components=1 \
    && rm /tmp/bisheng-jre.tar.gz \
    && /opt/bisheng-jre/bin/java -version

# Open-source GB/T 9704 font substitutes. Embedded OFD fonts always take precedence.
RUN mkdir -p /usr/share/fonts/truetype/gongwen \
    && curl -fsSL -o /tmp/zhuque.zip \
        "https://github.com/TrionesType/zhuque/releases/download/v${ZHUQUE_FANGSONG_VERSION}/ZhuqueFangsong-v${ZHUQUE_FANGSONG_VERSION}.zip" \
    && echo "bb8b661a7643d2296a72d9d10530a00949419c4e527fb61783f73c2ba1a8c062  /tmp/zhuque.zip" | sha256sum -c - \
    && unzip -p /tmp/zhuque.zip ZhuqueFangsong-Regular.ttf \
        > /usr/share/fonts/truetype/gongwen/ZhuqueFangsong-Regular.ttf \
    && rm /tmp/zhuque.zip \
    && ln -sf /usr/share/fonts/truetype/gongwen/ZhuqueFangsong-Regular.ttf \
        /usr/share/fonts/truetype/gongwen/simfang.ttf \
    && ln -sf /usr/share/fonts/truetype/arphic-gkai00mp/gkai00mp.ttf \
        /usr/share/fonts/truetype/gongwen/simkai.ttf \
    && ln -sf /usr/share/fonts/truetype/arphic-gbsn00lp/gbsn00lp.ttf \
        /usr/share/fonts/truetype/gongwen/simsun.ttf \
    && ln -sf /usr/share/fonts/truetype/wqy/wqy-zenhei.ttc \
        /usr/share/fonts/truetype/gongwen/simhei.ttc \
    && ln -sf /usr/share/fonts/truetype/arphic-gkai00mp/gkai00mp.ttf \
        /usr/share/fonts/truetype/gongwen/fzkai-z03s.ttf \
    && ln -sf /usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc \
        /usr/share/fonts/truetype/gongwen/fzxiaobiaosong-b05s.ttc \
    && fc-cache -f

COPY docker/ofd2pdf /usr/local/bin/ofd2pdf
COPY docker/99-gongwen-fonts.conf /etc/fonts/conf.d/99-gongwen-fonts.conf
COPY --from=ofd-build /build/target/ofd2pdf.jar /opt/ofd2pdf/ofd2pdf.jar

RUN chmod 0755 /usr/local/bin/ofd2pdf \
    && fc-cache -f

RUN groupadd --gid 10001 converter \
    && useradd \
        --uid 10001 \
        --gid converter \
        --create-home \
        --home-dir /home/converter \
        --shell /usr/sbin/nologin \
        converter

WORKDIR /app

COPY --from=uv /usr/local/bin/uv /usr/local/bin/uv

ENV JAVA_HOME=/opt/bisheng-jre \
    PATH="/opt/bisheng-jre/bin:/opt/venv/bin:$PATH" \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    VIRTUAL_ENV=/opt/venv \
    UV_LINK_MODE=copy \
    PYTHONPATH=/app/src

COPY pyproject.toml uv.lock README.md ./
ARG UV_OFFLINE=0
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    if [ "$UV_OFFLINE" = "1" ]; then \
        uv sync --locked --offline --no-dev --no-install-project; \
    else \
        uv sync --locked --no-dev --no-install-project; \
    fi

COPY src ./src

USER converter:converter

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/ready', timeout=3)"]

CMD ["uvicorn", "wps_converter.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]
