FROM python:3.12-slim

WORKDIR /app

# Dependencies first: they change rarely, so this layer stays cached
# when only the code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# Documentation only; the real port mapping is `docker run -p`.
EXPOSE 8000

# 0.0.0.0, not the default 127.0.0.1, so traffic from outside the container gets in.
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
