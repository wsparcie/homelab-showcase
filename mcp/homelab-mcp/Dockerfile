FROM python:3.13-slim
RUN pip install --no-cache-dir "mcp==1.30.0" && useradd -r -u 10001 mcp
COPY server.py /app/server.py
USER mcp
EXPOSE 8001
CMD ["python", "/app/server.py"]
