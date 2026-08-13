FROM python:3.12-slim

# Usuario no-root fijo (no viene baked-in como en nginx:alpine) -- mismo
# runAsUser se fija en base/deployment.yaml.
RUN useradd -u 1000 -m appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
