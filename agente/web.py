"""El chatbot de la tienda en una pagina web: el mismo grafo de agente.py, servido con FastAPI.

En local:   uvicorn web:app --port 8080        y abre http://localhost:8080
En la nube: el Dockerfile arranca esto mismo dentro de Azure Container Apps (ver azure/desplegar.sh).

    GET  /          la pagina del chat (static/index.html)
    POST /api/chat  {"hilo": "...", "mensaje": "..."} -> respuesta + como la ha resuelto (ruta, datos, traza)
    GET  /salud     health check: lo que mira Azure para saber si el contenedor esta vivo
"""

import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

import agente
import config

ESTATICOS = Path(__file__).parent / "static"
app_estado: dict = {}


@asynccontextmanager
async def ciclo_de_vida(app: FastAPI):
    """Al arrancar: un pool de conexiones a Neon para la memoria y el grafo compilado, una sola vez."""
    from langgraph.checkpoint.postgres import PostgresSaver
    from psycopg.rows import dict_row
    from psycopg_pool import ConnectionPool

    pool = ConnectionPool(
        config.DATABASE_URL,
        max_size=4,
        kwargs={"autocommit": True, "prepare_threshold": 0, "row_factory": dict_row},
        check=ConnectionPool.check_connection,  # Neon cierra conexiones inactivas: se comprueban antes de usarlas
    )
    memoria = PostgresSaver(pool)
    memoria.setup()
    app_estado["grafo"] = agente.construir(checkpointer=memoria)
    yield
    pool.close()


app = FastAPI(title="Agente de la tienda", lifespan=ciclo_de_vida)


class Mensaje(BaseModel):
    hilo: str = Field(min_length=1, max_length=64)
    mensaje: str = Field(min_length=1, max_length=500)


@app.get("/")
def pagina() -> FileResponse:
    return FileResponse(ESTATICOS / "index.html")


@app.get("/salud")
def salud() -> dict:
    return {"estado": "ok", "modelo": config.MODELO, "mcp": config.MCP_URL}


@app.post("/api/chat")
def chat(m: Mensaje) -> dict:
    """Un turno del agente. Es sincrono a proposito: FastAPI lo ejecuta en un hilo aparte."""
    grafo = app_estado["grafo"]
    t0 = time.perf_counter()
    respuesta = agente.turno(grafo, m.hilo, m.mensaje)
    valores = grafo.get_state({"configurable": {"thread_id": m.hilo}}).values
    return {
        "respuesta": respuesta,
        "ruta": valores.get("ruta"),
        "datos": valores.get("datos") or "",
        "segundos": round(time.perf_counter() - t0, 1),
        "modelo": config.MODELO,
        "traza": agente.ULTIMA_TRAZA.get(m.hilo),
    }
