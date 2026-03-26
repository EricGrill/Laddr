FROM python:3.12-slim

WORKDIR /app

ENV PYTHONPATH=/app:${PYTHONPATH}

RUN apt-get update && apt-get install -y \
    gcc \
    postgresql-client \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN pip install -e lib/laddr/

CMD ["python", "-m", "laddr.api.main"]
