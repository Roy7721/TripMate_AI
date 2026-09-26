# TripMate AI — how I built it

This is my development log. It covers every version, from the first hand-written tool to the
deployed v3, including the things that broke along the way and what I did about them.

I kept all three versions in the repository instead of overwriting them, because the interesting
part of this project is not the final code. It is how the design changed each time I hit a wall.

If you just want to run it, read the [README](README.md). This file is the story.

---

## The idea

I wanted a travel planner where the work is split across several agents instead of stuffed into
one big prompt: one agent for flights, one for hotels, one for weather, one to write the
itinerary. LangGraph gives me a graph with a shared state object, so each agent can be a node
that reads whatever the earlier nodes wrote.

I gave myself one rule at the start: **every version has to actually run end to end before I make
it cleverer.** That rule is the reason there are three versions and not one long refactor.

---

## v1 — hand-written tools

The goal for v1 was simply to get something working. No MCP, no supervisor, no cleverness.

- A Tavily wrapper for hotel search
- An AviationStack REST client for flights
- A fixed LangGraph pipeline: flight → hotel → itinerary → final
- FastAPI with a small web UI
- A PostgreSQL checkpointer, so a conversation can be continued later

### The route parser was the ugly part

AviationStack wants IATA codes. My user types *"Dhaka to Bangkok"*. So I wrote a parser: regular
expressions, plus `airportsdata`, plus `pycountry`, plus a table of cities and countries I filled
in by hand.

It worked for common cities and fell apart on anything unusual. I knew while writing it that this
was the weakest part of v1, and it is the main reason I moved to MCP in v2. Maintaining my own
city table is not something I want to be doing.

### First error: LangSmith could not resolve the host

```
Failed to resolve 'api.smith.langchain.com,'
```

I spent much longer on this than I would like to admit. The endpoint looked correct in `.env`. The
actual problem was a stray comma **inside** the quotes:

```
LANGSMITH_ENDPOINT = 'https://api.smith.langchain.com,'
```

The comma was being read as part of the hostname. I removed it and tracing worked.

**What I took from it:** read the error string literally. The comma is right there in the message,
sitting inside the quotes, and I read past it several times because I had already decided the
problem was my network.

Also worth saying: this was only a *tracing* error. The MCP tools had loaded fine the whole time. I
nearly started debugging the tools because of a failure that had nothing to do with them.

### Second error: Tavily "returned nothing"

My test script printed the list of tools but never printed a search result. I assumed the Tavily
connection was broken.

It was not. My test script did this:

```python
asyncio.run(tavily_mcp_search(query))     # the result is thrown away
```

The search had worked every time. I was discarding the return value.

```python
result = asyncio.run(tavily_mcp_search(query))
print(result)
```

**What I took from it:** before debugging the system, check whether the test itself is wrong.

### A design decision I made here

Should I bind every tool to the LLM and let it choose which to call?

For v1, no. Every bound tool's schema is sent with **every** request, so more tools means more
tokens spent and more chances of the model picking the wrong one. In v1 and v2 the flow is fixed
anyway, so I call the tools from code and keep the LLM for interpreting and writing.

I came back to this question in v3 and answered it differently — see the supervisor.

---

## v2 — swapping hand-written tools for MCP

The reason for v2 was the route parser. Rather than maintaining city tables myself, I wanted the
model to talk to proper flight tools and interpret whatever they returned.

I deliberately used **three different kinds of MCP server**, because I wanted to understand the
protocol from all sides:

| Server | Transport | Where it comes from |
|---|---|---|
| Tavily | Streamable HTTP | Hosted by Tavily — I just point at a URL |
| AviationStack | stdio, launched with `uvx` | A third-party package |
| Weather | stdio, Python | **I wrote this one myself** with `FastMCP`, over OpenWeatherMap |

Writing the weather server is what made MCP click for me. It is not magic — it is a process that
speaks a protocol over stdin and stdout, and once you have written one you understand what the
other two are doing.

### The error that took the longest

```
unknown async library, or not in async context
```

The root of it: LangGraph nodes are synchronous, MCP tools are asynchronous. The usual trick is
`nest_asyncio` plus `asyncio.run()` inside each node. On **Python 3.14 that stopped working** —
`anyio` could no longer tell whether it was inside an async context.

What I tried, in order:

1. `asyncio.run()` directly in each node → *"cannot be called from a running event loop"*
2. `nest_asyncio.apply()` → the unknown-async-library error above
3. Making the nodes `async def` → LangGraph's synchronous invoke path still calls them
   synchronously, so this did not help either

What actually fixed it: **one long-lived event loop, on a background thread, started once at
import.** Then a small helper:

```python
def run_async(coro, timeout: float = 120):
    return asyncio.run_coroutine_threadsafe(coro, _mcp_loop).result(timeout)
```

Every MCP call in the graph now goes through that single loop, so there is never a nested one. I
also made the `/api/travel` endpoint a plain `def` instead of `async def`, so FastAPI runs it in a
worker thread rather than blocking its own event loop. I had to learn that same lesson a second
time in v3.

Trade-offs I knowingly accepted at this point:

- A 120-second timeout, and a timed-out coroutine keeps running in the background
- The loop has to stay the Windows default (Proactor), because the stdio MCP servers need it
- **All requests share one PostgreSQL connection.** I wrote "fine for development, not for
  production" in my notes and moved on. That one came back to bite me — see the Azure section.

### Four smaller bugs found while getting v2 running

| Bug | What it did | Fix |
|---|---|---|
| `WEATHER_SERVER_PATH` pointed at `custom_weather_mcp_server.py`, but the file is `custom_mcp_server.py` | Weather failed every single time | Corrected the path |
| A `raise RuntimeError` sat outside its `if` block in `initialize_weather_tools` | It raised unconditionally | Re-indented it |
| `llm` was never defined in `mcp_client.py` | `extract_destination` raised `NameError` | Defined the LLM there |
| `mcp_app.py` called `uvicorn.run("app:app")` | It started the **v1** app instead of v2 | Changed to `"mcp_app:app"` |

That last one is my favourite, because for a while I was testing v2, looking at v1's output, and
could not work out why none of my changes were showing up.

### Groq problems

**The model was retired.** `llama-3.3-70b-versatile` started returning 404. I listed the models my
key can actually use and switched v2 to `openai/gpt-oss-120b`. v1 still runs `gpt-oss-20b`.

**The free tier allows 8,000 tokens per minute**, and `final_agent` was sending about 8,700. It got
a 413. Three changes fixed it:

- `compact_tavily()` — the raw Tavily MCP response is several thousand tokens of JSON, and I was
  feeding all of it into later prompts. Now it is trimmed to title, URL and a short snippet.
- Capped the itinerary at 350 words and the final answer at 600
- Set `max_tokens=2000`

The cost: shorter answers, and `hotel_results` became text instead of raw JSON. I noted at the time
that I had not checked `script.js` against that change.

After all this, a full v2 request returned HTTP 200 with flights, hotels, weather and an itinerary.

---

## The AviationStack wall

v1's flight section looked reasonable. v2's was vague and general. My first instinct was that the
third-party MCP server was bad, and I started looking at swapping it for the `server.py` setup from
the AviationStack docs.

**I tested before switching, and I am glad I did.**

I probed all eleven AviationStack endpoints directly with my key:

| Result | Endpoints |
|---|---|
| Works | `flights`, `flightsFuture`, `timetable` |
| `function_access_restricted` | `airports`, `airlines`, `routes`, `airplanes`, `cities`, `countries`, `taxes` |

Then I listed the twelve tools the MCP server exposes. **Only four** map to endpoints my plan
allows.

That explained the whole thing:

- **v1 worked because it called `/v1/flights`** — one of the three endpoints my free plan allows.
  So v1 genuinely had live flight data.
- **v2's flight agent called three blocked tools**, and called the two working ones with no
  arguments. It never had live data at all. The model was filling in from general knowledge and
  sounding confident about it.

So the MCP server was not the problem. A different server with the same key would have hit exactly
the same wall. I did not switch.

**This is a plan limit, not a code problem.** On a paid AviationStack plan the same code returns
live, accurate flight information. I am leaving it on the free plan for now, because this is a
portfolio project and nothing else in the system depends on it. Upgrading is a purchase, not a
rewrite.

One more thing I learned here: **`with_structured_output` is unreliable with gpt-oss on Groq.** I
got `tool_use_failed`, and the agent confidently announced "no direct flight" when the flight board
had in fact loaded fine. Asking the model for plain JSON and parsing it myself worked first time.

---

## Trip dates and return flights — an experiment I rolled back

I wanted real dates. No dates given means the trip starts **tomorrow**; an "N day trip" returns on
day N; an explicit range is used as given. I added a `trip_planner` node to extract and resolve
this, stored the dates in state so every downstream agent used the same ones, and taught
`flight_agent` to search an outbound and a return leg.

**It worked.** A full request returned 200 with correct dates and the assumptions stated in the
Trip Summary. Then I removed it.

Why I rolled it back:

- I had to set `BOARD_MIN_GAP_SECONDS = 75`, because the free plan allows roughly **one
  future-flights call per minute**. A request with a return leg therefore waits a minute between
  the two calls, pushing a full request to about three minutes.
- The return leg is usually inconclusive anyway: the departure board is **capped at 100 flights**,
  so "no flight found" at a big hub like Bangkok proves nothing.
- It made v2 substantially more complex for a feature the plan was throttling.

Findings from it that are still worth keeping:

- The arrivals board has **no "flying from" field**, so a return leg has to be built from the
  destination's *departure* board instead
- `'str' object has no attribute 'get'` coming out of the MCP server is really that server
  mishandling a rate-limit error — a confusing message hiding a simple cause
- The future board returns airport codes in **lowercase** (`bkk`), which broke my uppercase
  comparison until I spotted it

I saved that code outside the repository. It is a good candidate for v4 on a paid plan.

---

## Restructuring into v1 / v2 / v3

At this point the repo had `backend.py` next to `mcp_backend.py` next to `mcp_app.py`, and it was
getting hard to tell which file belonged to which idea.

I made each version **self-contained** — its own `app.py`, `backend.py`, `static/` and
`templates/` — so a Dockerfile can build a single folder without reaching into the others. The
`.env`, `pyproject.toml` and `uv.lock` stay shared at the repo root.

The cost is that `static/` and `templates/` are duplicated across versions. I decided that was
worth it: versions never import each other, so I can change v3 with no risk of breaking v1.

I used `git mv` for the renames (`mcp_app.py` → `v2/app.py`, `mcp_backend.py` → `v2/backend.py`) so
the file history survived. Then I fixed the imports that assumed the old names, and verified every
version still served `/`, `/health` and its static files — **without making a single LLM call.**

Two rules I set here and have kept since:

- Every version exposes the same `run_travel_agent(user_input, thread_id)` function
- Versions never import each other

---

## v3 — a supervisor, a guardrail, and a human in the loop

v3 started as an exact copy of v2. Then I changed four things.

**A supervisor.** One LLM call at the front that returns strict JSON: which specialists this
request actually needs, the trip constraints it could extract (destination, origin, duration,
budget, style, preferences), and its reasoning. Conditional edges then walk only the chosen agents.
A hotel-only question no longer triggers a flight lookup and a weather lookup. If the JSON cannot
be parsed it falls back to running everything — I would rather be slow than broken.

This is me revisiting the v1 design decision. Note that the supervisor picks *agents*, not *tools*
— each specialist still calls its own fixed set. Picking tools per agent is on the list for v4.

**An input guardrail**, in that same first node. Unrelated, harmful or illegal requests are refused
before any specialist runs. A request that is genuinely about travel but missing details is *not*
blocked — I did not want it rejecting real users for being vague.

**A budget agent**, for when the request actually mentions cost.

**Human approval.** The itinerary agent now produces a *draft*. A `human_approval` node calls
LangGraph's `interrupt()`, which pauses the run and saves it. `POST /api/travel/approve` resumes it
with `Command(resume={...})`. You approve it, or send it back with feedback that the final agent
applies. This is the feature I am most pleased with, and it is only possible because of the
PostgreSQL checkpointer — the paused run lives in the database, not in memory.

### The bug that taught me the most

After building v3 I reviewed it in layers: files compile, then graph structure, then environment,
then MCP servers, then real requests. The graph-structure layer found two bugs, and the first is
the most useful thing I learned in this whole project.

**`TravelState` declared `selected_agent`. My code wrote `selected_agents`.**

LangGraph **silently drops any key that is not in the state schema.** No error, no warning. So the
supervisor was doing its job perfectly, returning a well-formed list of agents — and that list was
thrown away on the way out of the node. Every single request went straight from
`supervisor → itinerary_agent`, skipping flight, hotel, weather and budget entirely.

The second bug was the same species: `approval_requests` in the state, `approval_request` in the
code, so the approval message vanished too.

The fix was two renames. Finding it was the work.

**How I proved it**, and this is the part I would do again: I ran the **real graph** with a **fake
LLM, fake tools and an in-memory checkpointer**. No API calls, no database writes, no cost, runs in
a second. Before the fix it printed `supervisor → itinerary_agent`. After the fix all five agents
ran in order; a "hotel only" request ran `hotel → itinerary`; and a blocked request stopped at the
guardrail.

**What I took from it:** with a `TypedDict` state, a misspelled key does not raise — it just
disappears. And I had been testing with live LLM calls, which are slow and cost money, so I was
testing *less* than I should have been. Faking the model makes the graph itself cheap to test, and
that would have caught this in the first minute.

### Then a real end-to-end run

| Request | Result |
|---|---|
| "Give me step by step instructions to hack into my neighbour's bank account." | Refused by the guardrail in 8s. No specialists ran. |
| "Plan a 3 day trip to Bangkok from Dhaka with hotels and weather." | 200 in 107s. Paused for approval. The supervisor picked flight, hotel, weather and itinerary — and **skipped budget**, because I had not mentioned cost. |
| Approve the draft | Final plan in 22s |
| Reject with no feedback | 400, as intended |

That skipped budget agent is the moment the supervisor stopped being an idea and started being a
thing that works.

---

## Taking v3 live on Azure

Building it is one thing. Putting it on a public URL surfaced a completely different set of
problems — and almost none of them were in the agent code.

### The bug I had written down and ignored

Back in v2 I wrote "all requests share one PostgreSQL connection — fine for development, not for
production" and moved on. Here is what that actually meant:

```python
_conn = psycopg.connect(DATABASE_URL, autocommit=True, row_factory=dict_row)
checkpointer = PostgresSaver(_conn)
```

One connection, opened when Python imports the module — so once, when the container starts — and
reused for the container's whole life. Nothing checks whether it is still alive. Nothing
reconnects.

For most apps that is merely bad. For **this** app it is fatal, and specifically because of the
feature I am proudest of. Human approval **requires** an idle gap: the visitor reads a 350-word
draft itinerary, thinks about it, and clicks Approve. That is one to five minutes with zero
database traffic — which is exactly how long a hosted PostgreSQL waits before closing an idle
connection. The socket dies, nothing tells my process, and the next checkpoint read fails with
`server closed the connection unexpectedly`. Approve breaks permanently, and so does every request
after it.

The nastiest part is that **scale-to-zero half hides it.** If the container happens to shut down
during the reading gap, a fresh one starts, opens a new connection, finds the paused run safely in
PostgreSQL, and Approve works fine. So it fails only when the container stays warm but the
connection does not — an intermittent bug in a window a few minutes wide.

The fix was a connection pool instead of a connection:

```python
_pool = ConnectionPool(
    conninfo=DATABASE_URL,
    min_size=0,          # hold nothing open while idle, so nothing goes stale
    max_size=4,
    max_idle=60,
    kwargs={"autocommit": True, "row_factory": dict_row, "prepare_threshold": None},
    check=ConnectionPool.check_connection,   # test before lending out; replace a dead one
    open=True,
)
```

`psycopg-pool` was already in my lock file, so this cost me nothing but the understanding.

I tested it the way I should have tested the earlier bug: killed a pooled connection deliberately,
then queried again. The pool discarded the dead one and made a fresh one, and the caller never saw
an error.

### My database had an expiry date

My PostgreSQL was on Render's free tier. Render's free PostgreSQL **expires 30 days after
creation**, then gives a 14-day grace period, then **deletes the database and all its data.**

For a portfolio project that is a trap. `backend.py` connects at *import* time, so an unreachable
database means the module never loads, uvicorn never starts, and `/health` never answers. Someone
opening my link after expiry would not see a database error — they would see a dead page and a
container in a restart loop.

I moved to Neon, which has no expiry, and put it in **Singapore** rather than Oregon, because the
app runs in Korea and every node of the graph writes a checkpoint. Neon suspends when idle, which
would be a problem — except that the pool fix above handles exactly that.

### Three failures at boundaries, not in code

Three separate things broke while deploying, all the same species: **a value passing through one
more shell than I expected.**

1. **`docker run --env-file .env` refused to start.** My `.env` was written `KEY = value` with
   spaces around the `=`. `python-dotenv` strips those, so everything worked locally for months.
   Docker's env parser does not, and rejects a variable name containing a space.

2. **My deploy script died on a warning.** `az` prints an extension notice to *stderr*. In Windows
   PowerShell 5.1, redirecting a native command's stderr wraps each line in an error record, and
   with `$ErrorActionPreference = "Stop"` a cosmetic warning became a fatal error.

3. **My Neon connection string was cut in half.** The URL ends
   `?sslmode=require&channel_binding=require`. On Windows `az` is `az.cmd`, a **batch file**, so
   `cmd.exe` re-parses every argument — and an unquoted `&` is a command separator. It tried to run
   `channel_binding=require` as a command. I tested embedded quotes and `^` escaping; **neither
   works.** The fix was to stop sending an `&` at all: the bare URL goes in, my own
   `get_database_url()` re-appends `sslmode=require`, and channel binding moves to the
   `PGCHANNELBINDING` environment variable, which has no special characters.

None of these were bugs in the application. All three were bugs at a boundary between two things
that parse text differently.

### The image was twice the size it needed to be

The push to Docker Hub kept timing out on my connection. Rather than just retrying, I looked at
what I was actually uploading:

```
655MB  RUN uv sync --frozen --no-dev --no-install-project
377MB  RUN useradd --create-home --uid 1000 app && chown -R app:app /app
118MB  RUN uv tool install aviationstack-mcp==1.8.1
```

That 377 MB layer contains **no new content at all.** Docker layers are immutable, so when
`chown -R` changes the owner of a file from an earlier layer, the **entire file** is copied into the
new one. My `chown -R app:app /app` touched all 15,075 files of the virtualenv, duplicating the
whole thing just to change ownership.

There were also two caches baked in that nothing reads at runtime: 266 MB left by `uv sync` and
51 MB by `uv tool install`.

Two changes: create the user **before** anything is written into `/app` and use `COPY --chown`, so
no `chown -R` is ever needed; and add `--no-cache` to both uv commands. Docker's own layer cache
still skips the step when the lock file has not changed, so ordinary rebuilds are unaffected.

**1,352 MB → 633 MB.** The push went through, and the Azure cold start got shorter too, because
Azure pulls those same bytes.

I also pre-installed the AviationStack MCP server at build time. Before that, the first flight
request in a fresh container spent 15–25 seconds resolving 40 packages from PyPI — out of the 240
seconds Azure Container Apps allows for a single request. Now `uvx` starts it with `--offline`,
which I verified with the container's network disabled, so a PyPI outage cannot break a live
request.

### Where it landed

| | Local | On Azure |
|---|---|---|
| Draft, all five specialists | 94.4s | **66.4s** |
| Approve, after a 90-second idle gap | 8.2s | **5.0s** |
| Sections in the final answer | 7/7 | 7/7 |
| Cold start from zero | — | **6s** |

It is **faster on Azure than on my own laptop**, because Korea → Singapore is a much shorter trip
for every checkpoint write than Bangladesh → Singapore was.

The image is tagged with the git commit SHA rather than `latest`, so every running container traces
back to an exact commit. The API keys are Container Apps secrets, injected by reference, never
plain environment variables. LangSmith tracing is deliberately switched off in production — a
public demo would ship every visitor's query to my LangSmith account and burn that quota.

---

## Known issues I have not fixed

I would rather write these down than pretend they are not there.

- **The guardrail fails open.** If its own LLM call or JSON parsing fails, the request is allowed
  through. It is a first line of defence, not a security boundary.
- **Approval is a single round.** A rejected draft goes straight to the final agent with the
  feedback; it is not shown again for a second approval.
- **Reloading the page loses a pending draft** in the UI, although the paused run is still safe in
  PostgreSQL. The UI just does not reattach to it yet.
- **The supervisor picks agents, not tools.** Each specialist still calls its own fixed set.
- **Dates are handled entirely by the LLM**, so with no dates in the request it may invent example
  ones.
- **No authentication or rate limiting** on the API.
- **Flight data is limited by the free AviationStack plan**, as described above.
- `weather_agent` calls the LLM through `extract_destination` but does not increment `llm_calls`, so
  that counter under-reports by one whenever weather runs.
- v3 shares the same database tables as v1 and v2.

---

## What's next — v4

v4 is coming. What I want in it:

- **Per-agent tool sets.** Give each specialist only the few MCP tools it needs, instead of fixed
  tool calls — the natural next step after a supervisor that picks agents.
- **Stream progress to the UI.** Right now you wait a minute looking at nothing. The agents finish
  one at a time and there is no reason not to show that as it happens.
- **A second approval round**, and a UI that reattaches to a pending draft after a reload.
- **A guardrail that fails closed**, plus tests for the routing and refusal paths — using the
  fake-LLM approach that caught the `selected_agents` bug.
- **Dates and return flights**, brought back from the experiment above, if I move to a paid
  AviationStack plan.

---

*Built by [Roy7721](https://github.com/Roy7721). v3 is
[running live](https://tripmate-ai.ashysmoke-d4f578eb.koreacentral.azurecontainerapps.io).*
