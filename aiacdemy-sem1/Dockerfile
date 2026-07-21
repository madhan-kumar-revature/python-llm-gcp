FROM python:3.12-slim
RUN apt-get update && apt-get install -y curl && \
    curl -L https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 \
    -o /usr/local/bin/ttyd && \
    chmod +x /usr/local/bin/ttyd && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD ["sh", "-c", "ttyd --port 7681 --writable --credential \"${TTYD_USER}:${TTYD_PASS}\" python3 main.py"]
