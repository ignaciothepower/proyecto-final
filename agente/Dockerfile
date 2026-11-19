# Imagen del chatbot de la tienda (proyecto final): el agente + su pagina web, listo para Azure Container Apps.
FROM python:3.12-slim

WORKDIR /app
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 HF_HOME=/app/.hf

# 1) torch en su version solo-CPU: sin GPU en el contenedor, y ocupa 4 veces menos que la normal
RUN pip install torch --index-url https://download.pytorch.org/whl/cpu

# 2) El resto de dependencias: si requirements.txt no cambia, Docker reutiliza esta capa
COPY requirements.txt .
RUN pip install -r requirements.txt

# 3) El modelo de embeddings del RAG se descarga al construir, no en la primera pregunta
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('paraphrase-multilingual-MiniLM-L12-v2')"
ENV HF_HUB_OFFLINE=1

# 4) El codigo, los documentos de la tienda y la pagina web
COPY *.py ./
COPY docs/ docs/
COPY static/ static/

# Nunca como root dentro del contenedor
RUN useradd --create-home app && chown -R app /app
USER app

EXPOSE 8000
CMD ["uvicorn", "web:app", "--host", "0.0.0.0", "--port", "8000"]
