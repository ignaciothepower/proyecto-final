"""Configuracion: TODO sale del entorno (.env en local, Secrets en GitHub). Ninguna clave en el codigo (S18)."""

import os

from dotenv import load_dotenv

load_dotenv()  # si no hay .env (por ejemplo en la CI) no pasa nada: se usan las variables ya definidas

# El LLM: Azure OpenAI si hay endpoint en el entorno (la version en la nube); si no, llama3.1 con Ollama (local)
AZURE_OPENAI = bool(os.environ.get("AZURE_OPENAI_ENDPOINT"))
if AZURE_OPENAI:
    MODELO = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4.1-mini")
else:
    MODELO = os.environ.get("MODELO", "llama3.1")  # el mismo LLM local de todo el master (Ollama)
MCP_URL = os.environ.get(
    "MCP_URL", "http://localhost:8000"
)  # el servidor MCP de la S15 (carpeta mcp/): local o en Azure
DATABASE_URL = os.environ.get("DATABASE_URL", "")  # Neon (S9): memoria del agente + PGVector
TABLA_RAG = "tienda_fragmentos"  # tabla propia, para no pisar la de la S10 (fragmentos)

NECESARIAS = ("DATABASE_URL", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_HOST")


def faltan() -> list[str]:
    """Nombres de las variables que faltan (nunca sus valores)."""
    return [n for n in NECESARIAS if not os.environ.get(n)]


def langfuse_activo() -> bool:
    return bool(os.environ.get("LANGFUSE_PUBLIC_KEY") and os.environ.get("LANGFUSE_SECRET_KEY"))


def crear_llm():
    """El LLM del nodo responder. Mismo grafo, dos cerebros: solo cambia el entorno."""
    if AZURE_OPENAI:
        from langchain_openai import AzureChatOpenAI  # lee AZURE_OPENAI_ENDPOINT, _API_KEY y OPENAI_API_VERSION

        return AzureChatOpenAI(azure_deployment=MODELO, temperature=0, max_tokens=300)
    from langchain_ollama import ChatOllama

    return ChatOllama(model=MODELO, temperature=0, num_predict=200)
