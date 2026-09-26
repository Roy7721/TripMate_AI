<div align="center">

# ✈️ TripMate AI

**A multi-agent travel planner built with LangGraph, FastAPI and the Model Context Protocol (MCP).**

Describe a trip in plain English. A supervisor agent screens the request, routes it to the specialist agents it needs (flights, hotels, weather, budget), and drafts an itinerary for you to review before the final plan is written. Earlier versions run a fixed pipeline instead.

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
- [What's new in each version](#whats-new-in-each-version)
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
4. **Weather information** *(v2, v3)*
5. **Day-by-day itinerary**
6. **Estimated budget**
7. **Final recommendations**

The web UI renders the result as Markdown and lets you copy it or download it as a **PDF**.

In **v3** the flow has two extra stages: the request is checked and routed first, and you approve (or send back for revision) a **draft itinerary** before the final plan is generated.

### Features

- 🧠 **Multi-agent system** built as a LangGraph `StateGraph`, with one node per responsibility
- 🧭 **Supervisor agent** *(v3)* that decides which specialists a request needs, so a hotel-only question does not trigger flights and weather
- 🛡️ **Input guardrail** *(v3)* that refuses unrelated, harmful or illegal requests before any specialist runs
- 🙋 **Human-in-the-loop approval** *(v3)*: the graph pauses on a draft itinerary and resumes when you approve or send feedback
- 🔌 **Two ways to give agents tools**: hand-written tool functions (v1) and MCP servers (v2, v3)
- 🌐 **MCP integration**: a hosted MCP server (Tavily), a third-party stdio MCP server (AviationStack) and a **custom MCP server** written for this project (weather)
- 💾 **Persistent conversations**: every run is checkpointed to PostgreSQL under a `thread_id`, which is also what lets a paused run resume
- 🖥️ **Clean web UI**: quick-start prompts, Markdown rendering, copy button, PDF export, `Ctrl+Enter` to submit. v3 adds an execution-plan panel and approve / revise controls
- 🐳 **Dockerfiles** for each version
- 🔭 **Optional LangSmith tracing** for inspecting every agent run

---

## Versions

The project is developed in stages. Each version lives in its own self-contained folder.

| Version | Folder | Tools | Agents | Status |
|---|---|---|---|---|
| **v1** | [`v1/`](v1/) | Hand-written Python tools (Tavily client, AviationStack REST client with a rule-based route parser) | Flight → Hotel → Itinerary → Final | ✅ Working |
| **v2** | [`v2/`](v2/) | MCP servers: Tavily, AviationStack, custom Weather | Flight → Hotel → Weather → Itinerary → Final | ✅ Working |
| **v3** | [`v3/`](v3/) | Same MCP servers as v2 | Guardrail + Supervisor → (Flight, Hotel, Weather, Budget: only those needed) → Itinerary → **Human approval** → Final | ✅ Working (first iteration) |
| **v4** | *not created yet* | — | — | 🔜 Coming soon |

---

## What's new in each version

### At a glance

| | v1 | v2 | v3 |
|---|:---:|:---:|:---:|
| Tool layer | Hand-written Python functions | MCP servers | MCP servers (same as v2) |
| Agent flow | Fixed, 4 steps | Fixed, 5 steps | **Chosen per request** by a supervisor |
| Weather agent | — | ✅ | ✅ |
| Custom MCP server (weather) | — | ✅ | ✅ |
| Dedicated budget agent | — | — | ✅ |
| Input guardrail (refuses off-topic / harmful requests) | — | — | ✅ |
| Human-in-the-loop approval | — | — | ✅ |
| Execution-plan panel and approval controls in the UI | — | — | ✅ |
| LLM (Groq) | `gpt-oss-20b` | `gpt-oss-120b` | `gpt-oss-120b` |

### v1 → v2: from hand-written tools to MCP

**Added**
- **MCP tools.** Tavily (hosted, streamable HTTP), AviationStack (stdio, launched with `uvx`) and a **custom weather MCP server** built with `FastMCP` on top of OpenWeatherMap (`get_current_weather`, `get_forecast`).
- **Weather agent**, and a weather section in the final answer. It asks the LLM for the destination city before looking up the weather.
- **A sync-to-async bridge** (`run_async`) so synchronous LangGraph nodes can call async MCP tools.
- A larger model, `gpt-oss-120b`.

**Changed**
- **The flight step.** v1 parsed the route with regular expressions and hand-written city and country tables, then called one AviationStack REST endpoint. v2 asks the AviationStack MCP tools (airports, airlines, routes, schedules) and lets the LLM interpret what they return, so the parsing tables are gone. Some of those tools need a paid AviationStack plan; without it the answer falls back on the model's own knowledge.
- **Token budgeting.** The itinerary and final answers are now capped in length (v1 had no cap), and the raw Tavily MCP output is trimmed to title, URL and a short snippet (v1's Tavily wrapper already did this), so requests fit the Groq free-tier limits.
- **The graph grew** from 4 nodes to 5 (Weather added).

**Unchanged:** the FastAPI app and web UI, PostgreSQL checkpointing, and the fixed, sequential pipeline.

### v2 → v3: from a fixed pipeline to a supervised system

**Added**
- **Supervisor agent.** One LLM call decides which specialists a request needs, extracts the trip constraints (destination, origin, duration, budget, style, preferences) and records its reasoning. If its output cannot be parsed, it runs every specialist.
- **Input guardrail.** Unrelated, harmful or illegal requests are refused before any specialist runs.
- **Budget agent.** A specialist that assesses cost and feasibility when the request calls for it.
- **Human-in-the-loop.** The run pauses on a draft itinerary (LangGraph `interrupt`) and resumes through the new `POST /api/travel/approve` endpoint. Approving produces the final plan. Rejecting requires feedback, which the final agent applies.
- **UI additions.** An execution-plan panel (supervisor reasoning, chosen agents, guardrail badge), a "Draft" label, and an approval panel with Approve and Revise buttons.
- **New API fields**, including `requires_approval`, `selected_agents`, `trip_constraints`, `supervisor_reasoning` and `guardrail_allowed`.

**Changed**
- **The pipeline is no longer fixed.** Only the selected specialists run and the itinerary agent always runs, so a hotel-only question no longer triggers flights and weather.
- **The itinerary is now a draft.** The final agent turns it into the final plan after human review, and the itinerary and final prompts now include the trip constraints and budget analysis.

**Unchanged:** the MCP servers and client, the flight, hotel and weather agents themselves, the model, and the PostgreSQL checkpointer.

### v4: coming soon 🔜

v4 is on the way. This section will describe what it adds once it lands.

---

## Architecture

### v3 (supervisor, guardrail, human approval)

```mermaid
flowchart TD
    User([User]) --> UI[Web UI]
    UI -->|POST /api/travel| Sup{{"Supervisor<br/>guardrail and routing"}}

    Sup -->|unsafe or off-topic| Block[Refusal message]
    Block --> Done([Response])

    Sup -->|only the agents it selects| Flight[Flight agent]
    Flight --> Hotel[Hotel agent]
    Hotel --> Weather[Weather agent]
    Weather --> Budget[Budget agent]
    Budget --> Itin[Itinerary agent]

    Itin --> Human[/"Human approval<br/>graph pauses here"/]
    Human -->|POST /api/travel/approve| Final[Final agent]
    Final --> Done

    Flight -. MCP .-> AV[(AviationStack MCP)]
    Hotel -. MCP .-> TV[(Tavily MCP)]
    Weather -. MCP .-> WX[(Weather MCP)]
```

The specialists always run in the order Flight → Hotel → Weather → Budget, but the supervisor only selects the ones the request needs, and the **itinerary agent always runs**. The pause at *Human approval* uses LangGraph's `interrupt()`; the paused state is saved by the PostgreSQL checkpointer, and `Command(resume=...)` continues it.

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
    weather_results: str   # v2, v3
    itinerary: str
    llm_calls: int
```

v3 extends it with the supervisor and approval fields:

```python
    guardrail_allowed: bool          # did the request pass the input guardrail?
    guardrail_reason: str
    selected_agents: list[str]       # which specialists the supervisor chose
    trip_constraints: dict           # destination, origin, duration, budget, style, preferences
    supervisor_reasoning: str
    budget_results: str
    approval_request: str            # message shown to the human reviewer
    approved: bool
    human_feedback: str              # revision notes when the draft is sent back
    final_response: str              # set when a request is refused
```

---

## Tech stack

| Layer | Technology |
|---|---|
| Agent orchestration | [LangGraph](https://langchain-ai.github.io/langgraph/) |
| LLM | [Groq](https://groq.com/) — `gpt-oss-20b` (v1), `gpt-oss-120b` (v2, v3) via `langchain-groq` |
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
├── v3/                          # Version 3: supervisor, guardrail, human-in-the-loop
│   ├── app.py                   #   FastAPI app (+ /api/travel/approve)
│   ├── backend.py               #   Supervisor + guardrail + specialists + approval graph
│   ├── mcp_client.py            #   MCP client + sync→async bridge
│   ├── custom_mcp_server.py     #   Custom weather MCP server (FastMCP)
│   ├── static/  templates/      #   Web UI with execution-plan panel and approval controls
│   └── Dockerfile
│
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
OPENWEATHER_API_KEY=your_openweather_key      # v2 and v3
DATABASE_URL=postgresql://user:password@host:5432/dbname
DEFAULT_ORIGIN_IATA=DAC                        # optional, default departure airport
```

### 3. Run a version

Run from **inside the version's folder**:

```bash
# Version 3 (supervisor + guardrail + human approval)
cd v3
uv run uvicorn app:app --reload

# or Version 2 (MCP, fixed pipeline)
cd v2
uv run uvicorn app:app --reload

# or Version 1 (hand-written tools)
cd v1
uv run uvicorn app:app --reload
```

Open **http://127.0.0.1:8000** and try one of the quick prompts.

In **v3** the result first appears as a **draft itinerary** with an approval panel. Click **Approve & Generate Final**, or type feedback and click **Revise Using Feedback**, to get the final plan.

> ⏱️ A full plan takes a while. In one v3 test run the draft took about 1 minute 45 seconds and the final answer another 20 seconds. The agents run one after another, several LLM calls are involved, and each MCP tool call starts its own connection or subprocess.

### List the MCP tools (optional)

```bash
uv run scripts/test.py
```

This connects to the Tavily, AviationStack and weather MCP servers and prints the tools each one offers.

---

## Configuration

| Variable | Required | Used by | Description |
|---|---|---|---|
| `GROQ_API_KEY` | ✅ | v1, v2, v3 | Groq API key for the LLM |
| `TAVILY_API_KEY` | ✅ | v1, v2, v3 | Tavily web search (hotels) |
| `AVIATIONSTACK_API_KEY` | ✅ | v1, v2, v3 | AviationStack flight data |
| `OPENWEATHER_API_KEY` | ✅ (v2, v3) | v2, v3 | OpenWeatherMap key for the weather MCP server |
| `DATABASE_URL` | ✅ | v1, v2, v3 | PostgreSQL connection string for LangGraph checkpoints (v3 also needs it to pause and resume) |
| `DEFAULT_ORIGIN_IATA` | ❌ | v1 | Departure airport when none is given (default `DAC`) |
| `LANGSMITH_TRACING` | ❌ | v1, v2, v3 | Set to `true` to enable LangSmith tracing |
| `LANGSMITH_API_KEY` | ❌ | v1, v2, v3 | LangSmith API key |
| `LANGSMITH_PROJECT` | ❌ | v1, v2, v3 | LangSmith project name |

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

#### v3 response

v3 returns the fields above plus the supervisor and approval information. For a normal request the run **pauses**, so `requires_approval` is `true` and `answer` / `itinerary` hold the **draft**:

```json
{
  "success": true,
  "thread_id": "user_3f9c…",
  "requires_approval": true,
  "approval_request": "Please review the generated draft itinerary. …",
  "answer": "**Bangkok – 3-Day Quick-Trip** …",
  "itinerary": "**Bangkok – 3-Day Quick-Trip** …",
  "selected_agents": ["flight_agent", "hotel_agent", "weather_agent", "itinerary_agent"],
  "trip_constraints": { "destination": "Bangkok", "origin": "Dhaka", "duration": "3 days" },
  "supervisor_reasoning": "…",
  "guardrail_allowed": true,
  "guardrail_reason": "",
  "flight_results": "…",
  "hotel_results": "…",
  "weather_results": "…",
  "budget_results": "",
  "approved": false,
  "human_feedback": "",
  "llm_calls": 5
}
```

A request the guardrail refuses returns `guardrail_allowed: false`, an empty `selected_agents`, `requires_approval: false`, and the refusal text in `answer`.

### `POST /api/travel/approve` *(v3)*

Resumes a paused run.

```bash
curl -X POST http://127.0.0.1:8000/api/travel/approve \
  -H "Content-Type: application/json" \
  -d '{"thread_id": "user_3f9c…", "approved": true}'
```

| Field | Type | Description |
|---|---|---|
| `thread_id` | string | The `thread_id` returned by `/api/travel` |
| `approved` | boolean | `true` to accept the draft, `false` to request changes |
| `feedback` | string | Revision notes. **Required when `approved` is `false`**, otherwise the API answers `400` |

The response has the same shape as above, with the final plan in `answer` and `requires_approval: false`.

### `GET /health`

Returns `{"status": "ok", "message": "AI Travel Planner API is running"}`.

### `GET /`

Serves the web UI.

---

## Docker

Each version has its own Dockerfile. **Build from the repository root**, because all versions share `pyproject.toml` and `uv.lock`:

```bash
docker build -f v3/Dockerfile -t tripmate-v3 .
docker run --rm -p 8000:8000 --env-file .env tripmate-v3
```

Use `v1/Dockerfile` / `tripmate-v1` or `v2/Dockerfile` / `tripmate-v2` for the other versions. The `.env` file is excluded from the image by `.dockerignore` and passed in at run time, so no secrets are baked into it.

The v2 and v3 images keep `uvx` because the AviationStack MCP server is started with `uvx aviationstack-mcp`. The container therefore needs internet access, and the first flight lookup downloads that package.

---

## Design notes

**One responsibility per node.** Flight, hotel, weather, budget, itinerary and final-response logic are separate LangGraph nodes that share a typed state. Adding a step means adding a node and an edge.

**Persistent state.** The graph is compiled with a `PostgresSaver` checkpointer, so every run is stored under its `thread_id`. The UI keeps the thread ID in `localStorage`.

**Supervisor routing (v3).** One LLM call returns strict JSON: which specialists to run, the trip constraints it extracted (destination, origin, duration, budget, style, preferences) and its reasoning. Conditional edges then walk only through the selected agents in a fixed order, and the itinerary agent is always added. If the supervisor's JSON cannot be parsed, it falls back to running every specialist.

**Input guardrail (v3).** The same first node asks the model whether the request is about travel. Unrelated, harmful or illegal requests go to a refusal node and end the run; a valid request with missing details is not blocked. In testing, a request for bank-hacking instructions was refused in a few seconds without any specialist running.

**Human-in-the-loop (v3).** After the itinerary agent, a `human_approval` node calls LangGraph's `interrupt()`, which pauses the run and saves it in PostgreSQL. `POST /api/travel/approve` resumes it with `Command(resume={"approved": ..., "feedback": ...})`. Approving polishes the draft into the final plan; rejecting requires feedback, which the final agent applies.

**Three kinds of MCP server (v2, v3).**

| Server | Transport | Source |
|---|---|---|
| Tavily | Streamable HTTP | Hosted by Tavily |
| AviationStack | stdio (`uvx aviationstack-mcp`) | Third-party package |
| Weather | stdio (Python) | **Written for this project** with `FastMCP`; wraps OpenWeatherMap |

**Sync graph, async tools.** LangGraph nodes here are synchronous, while MCP tools are async. `mcp_client.py` (v2 and v3) runs one long-lived event loop on a background thread and exposes `run_async(coro)`, so nodes can call async MCP tools without nesting event loops.

**Token budgeting.** Search results are trimmed to title, URL and a short snippet before they reach later prompts, which keeps requests inside the token limits of Groq's free tier.

**Live flight data, not prices.** The flight step shows live or scheduled flight information. Flight APIs like AviationStack do not return fares, so any price range in the answer is an estimate by the model.

---

## Known limitations

This is a portfolio project and is **not production-ready**.

- **No ticket prices.** Fares are model estimates, not live quotes.
- **Flight data depends on your AviationStack plan.** Some endpoints (airport, airline and route listings) require a paid plan. When live data is unavailable, the flight section falls back on the model's general knowledge.
- **Dates are handled by the LLM.** There is no date-parsing or availability search. The model interprets phrases like "next week" itself.
- **Slow requests.** The agents run one after another and each step waits for the previous one. A v3 travel request took roughly two minutes end to end in testing.
- **The v3 guardrail fails open.** If the guardrail's own LLM call or JSON parsing fails, the request is allowed through. It is a first line of defence, not a security boundary.
- **Approval is a single round.** A rejected draft goes straight to the final agent with your feedback; it is not shown to you again for a second approval.
- **A reloaded page forgets a pending draft.** The paused run is still saved on the server, but the UI does not yet reattach to it.
- **The supervisor picks agents, not tools.** Each specialist still calls its own fixed set of tools.
- **Invented dates.** With no dates in the request, the model may pick example dates for the itinerary.
- **v1 route parsing is rule-based.** It uses regular expressions, `airportsdata`, `pycountry` and a small hand-written city and country table, so unusual place names may not resolve.
- **No authentication or rate limiting** on the API.
- **Free-tier limits.** Groq, AviationStack and Tavily free plans have request or token limits that can cause failures under heavy use.
- **The Dockerfiles are new and largely untested.** Treat them as a starting point and expect to tweak them.

---

## Roadmap

**Done in v3**

- [x] **Supervisor agent** that routes each request to the specialist agents it needs instead of running a fixed pipeline
- [x] **Human-in-the-loop** approval before the final plan, using LangGraph `interrupt` and the PostgreSQL checkpointer
- [x] **Input guardrail** that blocks illegal, unsafe or off-topic requests before any specialist runs
- [x] **Budget agent** and an execution-plan panel in the UI

**Next**

- [ ] **Per-agent tool sets**: give each worker only the few MCP tools it needs, instead of fixed tool calls
- [ ] Smarter date handling and return-flight search
- [ ] A second approval round after a revision, and a UI that reattaches to a pending draft after a reload
- [ ] A guardrail that fails closed, plus tests for the routing and refusal paths
- [ ] Stream agent progress to the UI instead of one long wait

---

<div align="center">

Built by [Roy7721](https://github.com/Roy7721)

</div>
