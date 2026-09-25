<div align="center">

# ✈️ TripMate AI

**A multi-agent travel planner built with LangGraph, FastAPI and the Model Context Protocol (MCP).**

Describe a trip in plain English. A pipeline of specialised agents researches flights, hotels and weather, then writes a complete day-by-day itinerary with a budget.

![Python](https://img.shields.io/badge/Python-3.14+-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-009688?logo=fastapi&logoColor=white)
![LangGraph](https://img.shields.io/badge/LangGraph-multi--agent-1C3C3C)
![MCP](https://img.shields.io/badge/MCP-tools-6E56CF)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-checkpoints-4169E1?logo=postgresql&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Dockerfiles-2496ED?logo=docker&logoColor=white)

</div>

---

## Table of contents

- [What it does](#what-it-does)
- [Versions](#versions)
- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Project structure](#project-structure)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [API](#api)
- [Docker](#docker)
- [Design notes](#design-notes)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)

---

## What it does

Type a request such as:

> *Plan a complete 7 days Japan trip from Bangladesh including flights, hotels and sightseeing under 2 lakhs.*

TripMate AI runs it through a chain of agents and returns a formatted plan:

1. **Trip summary**
2. **Flight information**
3. **Hotel suggestions**
4. **Weather information** *(v2)*
5. **Day-by-day itinerary**
6. **Estimated budget**
7. **Final recommendations**

The web UI renders the result as Markdown and lets you copy it or download it as a **PDF**.

### Features

- 🧠 **Multi-agent pipeline** built as a LangGraph `StateGraph`, with one node per responsibility
- 🔌 **Two ways to give agents tools**: hand-written tool functions (v1) and MCP servers (v2)
- 🌐 **MCP integration**: a hosted MCP server (Tavily), a third-party stdio MCP server (AviationStack) and a **custom MCP server** written for this project (weather)
- 💾 **Persistent conversations**: every run is checkpointed to PostgreSQL under a `thread_id`
- 🖥️ **Clean web UI**: quick-start prompts, Markdown rendering, copy button, PDF export, `Ctrl+Enter` to submit
- 🐳 **Dockerfiles** for each version
- 🔭 **Optional LangSmith tracing** for inspecting every agent run

---

## Versions

The project is developed in stages. Each version lives in its own self-contained folder.

| Version | Folder | Tools | Agents | Status |
|---|---|---|---|---|
| **v1** | [`v1/`](v1/) | Hand-written Python tools (Tavily client, AviationStack REST client with a rule-based route parser) | Flight → Hotel → Itinerary → Final | ✅ Working |
| **v2** | [`v2/`](v2/) | MCP servers: Tavily, AviationStack, custom Weather | Flight → Hotel → Weather → Itinerary → Final | ✅ Working |
| **v3** | [`v3/`](v3/) | — | Supervisor agent, human-in-the-loop approval, request guardrails | 🚧 Planned |

---

## Architecture

### v2 (MCP)

```mermaid
flowchart LR
    User([User]) --> UI[Web UI]
    UI -->|POST /api/travel| API[FastAPI]
    API --> Flight

    subgraph Pipeline[LangGraph pipeline]
        direction LR
        Flight[Flight agent] --> Hotel[Hotel agent]
        Hotel --> Weather[Weather agent]
        Weather --> Itinerary[Itinerary agent]
        Itinerary --> Final[Final agent]
    end

    Flight -. MCP .-> AV[(AviationStack MCP)]
    Hotel -. MCP .-> TV[(Tavily MCP)]
    Weather -. MCP .-> WX[(Weather MCP)]

    Flight -.-> LLM{{Groq LLM}}
    Itinerary -.-> LLM
    Final -.-> LLM

    Pipeline <--> PG[(PostgreSQL checkpoints)]
    Final --> API
```

### v1 (hand-written tools)

```
START → flight_agent → hotel_agent → itinerary_agent → final_agent → END
            │               │
   AviationStack REST     Tavily
```

### Shared state

Every node reads from and writes to one typed state object:

```python
class TravelState(TypedDict):
    messages: Annotated[list[AnyMessage], operator.add]
    user_query: str
    flight_results: str
    hotel_results: str
    weather_results: str   # v2 only
    itinerary: str
    llm_calls: int
```

---

## Tech stack

| Layer | Technology |
|---|---|
| Agent orchestration | [LangGraph](https://langchain-ai.github.io/langgraph/) |
| LLM | [Groq](https://groq.com/) — `gpt-oss-20b` (v1), `gpt-oss-120b` (v2) via `langchain-groq` |
| Tools protocol | [Model Context Protocol](https://modelcontextprotocol.io/) via `langchain-mcp-adapters` and `FastMCP` |
| Backend | FastAPI, Uvicorn |
| Frontend | Vanilla HTML / CSS / JS, `marked` (Markdown), `html2pdf.js` (PDF export) |
| Persistence | PostgreSQL through `langgraph-checkpoint-postgres` |
| Data sources | Tavily (web search), AviationStack (flights), OpenWeatherMap (weather) |
| Observability | LangSmith (optional) |
| Packaging | [uv](https://docs.astral.sh/uv/), Docker |

---

## Project structure

```
TripMate_AI/
├── v1/                          # Version 1: hand-written tools
│   ├── app.py                   #   FastAPI app
│   ├── backend.py               #   LangGraph pipeline
│   ├── tools/
│   │   ├── flight_tool.py       #   AviationStack client + route parser
│   │   └── tavily_tool.py       #   Tavily search wrapper
│   ├── static/  templates/      #   Web UI
│   └── Dockerfile
│
├── v2/                          # Version 2: MCP tools
│   ├── app.py                   #   FastAPI app
│   ├── backend.py               #   LangGraph pipeline
│   ├── mcp_client.py            #   MCP client + sync→async bridge
│   ├── custom_mcp_server.py     #   Custom weather MCP server (FastMCP)
│   ├── static/  templates/      #   Web UI
│   └── Dockerfile
│
├── v3/                          # Version 3: supervisor, HITL, guardrails (planned)
├── scripts/                     # Scratch scripts, e.g. list available MCP tools
├── pyproject.toml               # Dependencies (shared by all versions)
├── uv.lock
└── README.md
```

---

## Getting started

### Prerequisites

- **Python 3.14+**
- **[uv](https://docs.astral.sh/uv/getting-started/installation/)** (also provides `uvx`, which v2 uses to launch the AviationStack MCP server)
- A **PostgreSQL** database (a free hosted one works well)
- API keys — see [Configuration](#configuration)

### 1. Clone and install

```bash
git clone https://github.com/Roy7721/TripMate_AI.git
cd TripMate_AI
uv sync
```

### 2. Create your `.env`

Create a `.env` file in the **repository root** (it is git-ignored). All versions read it.

```env
GROQ_API_KEY=your_groq_key
TAVILY_API_KEY=your_tavily_key
AVIATIONSTACK_API_KEY=your_aviationstack_key
OPENWEATHER_API_KEY=your_openweather_key      # v2 only
DATABASE_URL=postgresql://user:password@host:5432/dbname
DEFAULT_ORIGIN_IATA=DAC                        # optional, default departure airport
```

### 3. Run a version

Run from **inside the version's folder**:

```bash
# Version 2 (MCP)
cd v2
uv run uvicorn app:app --reload

# or Version 1 (hand-written tools)
cd v1
uv run uvicorn app:app --reload
```

Open **http://127.0.0.1:8000** and try one of the quick prompts.

> ⏱️ A full plan takes a while (often a minute or more). The agents run one after another, several LLM calls are involved, and in v2 each MCP tool call starts its own connection or subprocess.

### List the MCP tools (optional)

```bash
uv run scripts/test.py
```

This connects to the Tavily, AviationStack and weather MCP servers and prints the tools each one offers.

---

## Configuration

| Variable | Required | Used by | Description |
|---|---|---|---|
| `GROQ_API_KEY` | ✅ | v1, v2 | Groq API key for the LLM |
| `TAVILY_API_KEY` | ✅ | v1, v2 | Tavily web search (hotels) |
| `AVIATIONSTACK_API_KEY` | ✅ | v1, v2 | AviationStack flight data |
| `OPENWEATHER_API_KEY` | ✅ (v2 only) | v2 | OpenWeatherMap key for the weather MCP server |
| `DATABASE_URL` | ✅ | v1, v2 | PostgreSQL connection string for LangGraph checkpoints |
| `DEFAULT_ORIGIN_IATA` | ❌ | v1 | Departure airport when none is given (default `DAC`) |
| `LANGSMITH_TRACING` | ❌ | v1, v2 | Set to `true` to enable LangSmith tracing |
| `LANGSMITH_API_KEY` | ❌ | v1, v2 | LangSmith API key |
| `LANGSMITH_PROJECT` | ❌ | v1, v2 | LangSmith project name |

**Database SSL:** if `DATABASE_URL` has no `sslmode=` parameter, the app appends `sslmode=require` (suitable for hosted databases). For a local PostgreSQL without SSL, add `?sslmode=disable` to the URL.

---

## API

### `POST /api/travel`

```bash
curl -X POST http://127.0.0.1:8000/api/travel \
  -H "Content-Type: application/json" \
  -d '{"message": "Plan a 5 days Dubai trip from Dhaka with flights, hotels and sightseeing."}'
```

<details>
<summary>PowerShell equivalent</summary>

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8000/api/travel `
  -ContentType "application/json" `
  -Body '{"message": "Plan a 5 days Dubai trip from Dhaka with flights, hotels and sightseeing."}'
```

</details>

**Request body**

| Field | Type | Description |
|---|---|---|
| `message` | string | The travel request |
| `thread_id` | string, optional | Reuse a value from an earlier response to continue the same checkpointed thread. Omit it to start a new one. |

**Response**

```json
{
  "success": true,
  "thread_id": "user_3f9c…",
  "answer": "## Trip Summary …",
  "flight_results": "…",
  "hotel_results": "…",
  "itinerary": "…",
  "llm_calls": 4
}
```

*(Example values. `llm_calls` counts the LLM-backed steps and differs between versions.)*

### `GET /health`

Returns `{"status": "ok", "message": "AI Travel Planner API is running"}`.

### `GET /`

Serves the web UI.

---

## Docker

Each version has its own Dockerfile. **Build from the repository root**, because all versions share `pyproject.toml` and `uv.lock`:

```bash
docker build -f v2/Dockerfile -t tripmate-v2 .
docker run --rm -p 8000:8000 --env-file .env tripmate-v2
```

Use `v1/Dockerfile` and `tripmate-v1` for version 1. The `.env` file is excluded from the image by `.dockerignore` and passed in at run time, so no secrets are baked into it.

The v2 image keeps `uvx` because the AviationStack MCP server is started with `uvx aviationstack-mcp`. The container therefore needs internet access, and the first flight lookup downloads that package.

---

## Design notes

**One responsibility per node.** Flight, hotel, weather, itinerary and final-response logic are separate LangGraph nodes that share a typed state. Adding a step means adding a node and an edge.

**Persistent state.** The graph is compiled with a `PostgresSaver` checkpointer, so every run is stored under its `thread_id`. The UI keeps the thread ID in `localStorage`.

**Three kinds of MCP server (v2).**

| Server | Transport | Source |
|---|---|---|
| Tavily | Streamable HTTP | Hosted by Tavily |
| AviationStack | stdio (`uvx aviationstack-mcp`) | Third-party package |
| Weather | stdio (Python) | **Written for this project** with `FastMCP`; wraps OpenWeatherMap |

**Sync graph, async tools.** LangGraph nodes here are synchronous, while MCP tools are async. `v2/mcp_client.py` runs one long-lived event loop on a background thread and exposes `run_async(coro)`, so nodes can call async MCP tools without nesting event loops.

**Token budgeting.** Search results are trimmed to title, URL and a short snippet before they reach later prompts, which keeps requests inside the token limits of Groq's free tier.

**Live flight data, not prices.** The flight step shows live or scheduled flight information. Flight APIs like AviationStack do not return fares, so any price range in the answer is an estimate by the model.

---

## Known limitations

This is a portfolio project and is **not production-ready**.

- **No ticket prices.** Fares are model estimates, not live quotes.
- **Flight data depends on your AviationStack plan.** Some endpoints (airport, airline and route listings) require a paid plan. When live data is unavailable, the flight section falls back on the model's general knowledge.
- **Dates are handled by the LLM.** There is no date-parsing or availability search. The model interprets phrases like "next week" itself.
- **Slow requests.** The pipeline is sequential and each step waits for the previous one.
- **v1 route parsing is rule-based.** It uses regular expressions, `airportsdata`, `pycountry` and a small hand-written city and country table, so unusual place names may not resolve.
- **No authentication or rate limiting** on the API.
- **Free-tier limits.** Groq, AviationStack and Tavily free plans have request or token limits that can cause failures under heavy use.
- **The Dockerfiles are new and largely untested.** Treat them as a starting point and expect to tweak them.

---

## Roadmap

**v3** (planned; the [`v3/`](v3/) folder is reserved)

- [ ] **Supervisor agent** that routes each request to specialist worker agents instead of running a fixed pipeline
- [ ] **Human-in-the-loop** approval before costly steps, using LangGraph `interrupt` and the existing PostgreSQL checkpointer
- [ ] **Guardrails** that block illegal, unsafe or off-topic requests before any agent runs
- [ ] **Per-agent tool sets**: give each worker only the few MCP tools it needs, instead of every tool
- [ ] Smarter date handling and return-flight search

---

<div align="center">

Built by [Roy7721](https://github.com/Roy7721)

</div>
