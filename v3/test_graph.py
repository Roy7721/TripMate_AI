"""Offline tests for the v3 graph: routing, guardrail and human-in-the-loop.

Run it:      uv run v3/test_graph.py
Exit code:   0 = all checks passed, 1 = something failed.

This is a plain script, not a pytest suite. If pytest is ever added to the
project it will try to collect the test_* functions below and fail on their
arguments, so either rename this file or wrap them in fixtures first.

WHY THIS EXISTS
---------------
Two different things can break in this app:

  1. the plumbing  - which agent runs after which        -> our code
  2. the brain     - whether the answers are any good    -> the LLM

When a request misbehaves it is hard to tell which one is at fault. This file
tests ONLY the plumbing, by replacing the brain with a puppet that says exactly
what we tell it to. If the result is still wrong, the LLM is not to blame.

It imports the REAL backend: the real nodes, prompts, edges and state. Only the
outside world is swapped out:

    llm           -> FakeLLM        (no Groq calls)
    MCP tools     -> fixed strings  (no Tavily / AviationStack / OpenWeather)
    PostgresSaver -> MemorySaver    (no checkpoint rows written)

So it runs in about two seconds, costs nothing and uses no paid API quota -
cheap enough to run after every edit.

ONE CAVEAT: backend.py connects to PostgreSQL and calls checkpointer.setup()
at import time, so DATABASE_URL in .env must still be set and reachable, and
importing this file opens one connection (and creates the checkpoint tables if
they are missing). The test runs themselves write nothing there - they use
MemorySaver. A PythonFinalizationError from psycopg's pool on exit is harmless
noise from that same import-time connection.

WHAT IT CANNOT TELL YOU
-----------------------
The puppet always returns perfect JSON. This file cannot tell you whether the
real model picks sensible agents, or whether the guardrail catches a cleverly
worded harmful request. That still needs a real request against the running app.

    this file  -> is my wiring correct?
    real run   -> is my prompting good?

HISTORY
-------
This is the test that caught the bug where TravelState declared `selected_agent`
while the code used `selected_agents`. LangGraph silently drops state keys that
are not in the schema, so the supervisor's choice vanished and every request ran
`supervisor -> itinerary_agent`. The puppet had asked for all five agents, which
proved the choice was made correctly and then lost - pointing straight at the
typo instead of at the prompt.
"""

import json
import sys
from pathlib import Path

# Import the real backend the same way uvicorn does, from inside v3/.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import backend as b  # noqa: E402
from langchain_core.messages import AIMessage  # noqa: E402
from langgraph.checkpoint.memory import MemorySaver  # noqa: E402
from langgraph.types import Command  # noqa: E402

ALL_AGENTS = [
    "flight_agent",
    "hotel_agent",
    "weather_agent",
    "budget_agent",
    "itinerary_agent",
]


# =========================================================================
# The puppet: answers instead of Groq, based on which prompt it was sent
# =========================================================================

class FakeLLM:
    """Stands in for ChatGroq. Returns canned answers, never calls the network.

    Test cases steer it through markers in the user's message:
      "BLOCKME"   -> the guardrail refuses the request
      "HOTELONLY" -> the supervisor selects only the hotel agent
    """

    def invoke(self, messages, *args, **kwargs):
        text = (
            " ".join(getattr(m, "content", str(m)) for m in messages)
            if isinstance(messages, list)
            else str(messages)
        )

        if "input guardrail" in text:
            allowed = "BLOCKME" not in text
            return AIMessage(content=json.dumps({
                "allowed": allowed,
                "reason": "" if allowed else "Not a travel request.",
            }))

        if "supervisor of a multi-agent" in text:
            chosen = (
                ["hotel_agent", "itinerary_agent"]
                if "HOTELONLY" in text
                else ALL_AGENTS
            )
            return AIMessage(content=json.dumps({
                "selected_agents": chosen,
                "trip_constraints": {"destination": "Bangkok"},
                "reasoning": "stub supervisor decision",
            }))

        # Every other node (flight, budget, itinerary, final) just needs text.
        return AIMessage(content="STUB TEXT")


def install_fakes():
    """Swap the LLM, the MCP tools and the checkpointer. Return the test graph."""
    b.llm = FakeLLM()

    # run_async normally hands a coroutine to the background event loop; the
    # fake tools below are plain functions, so it becomes a pass-through.
    b.run_async = lambda value: value
    b.tavily_mcp_search = lambda query: "stub hotel search results"
    b.aviation_mcp_call = lambda name, args=None: f"stub {name}"
    b.weather_mcp_search = lambda city: "stub current weather"
    b.forecast_mcp_search = lambda city: "stub forecast"
    b.extract_destination = lambda query: "Bangkok"

    # The same graph object app.py uses, with in-memory checkpoints so that
    # interrupt() and Command(resume=...) work without touching PostgreSQL.
    return b.graph.compile(checkpointer=MemorySaver())


# =========================================================================
# Tiny test harness
# =========================================================================

failures = []


def check(name, passed, detail=""):
    print(f"  [{'PASS' if passed else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))
    if not passed:
        failures.append(name)


def initial_state(message):
    """Mirrors the input built by run_travel_agent() in backend.py."""
    return {
        "messages": [b.HumanMessage(content=message)],
        "user_query": message,
        "guardrail_allowed": True,
        "guardrail_reason": "",
        "selected_agents": [],
        "trip_constraints": b._empty_constraints(),
        "supervisor_reasoning": "",
        "flight_results": "",
        "hotel_results": "",
        "weather_results": "",
        "budget_results": "",
        "itinerary": "",
        "approval_request": "",
        "approved": False,
        "human_feedback": "",
        "final_response": "",
        "llm_calls": 0,
    }


def nodes_that_ran(graph, payload, config):
    """Stream one run and return the node names in the order they executed."""
    return [
        node
        for event in graph.stream(payload, config, stream_mode="updates")
        for node in event
        if not node.startswith("__")
    ]


# =========================================================================
# Test cases
# =========================================================================

def test_full_trip(graph):
    print("\n1. A normal travel request runs every selected specialist, then pauses")
    config = {"configurable": {"thread_id": "test-full-trip"}}

    ran = nodes_that_ran(graph, initial_state("Plan a 5 day trip to Bangkok"), config)
    check("supervisor runs first", ran[:1] == ["supervisor"], " -> ".join(ran))
    check("all five specialists run, in order", ran[1:] == ALL_AGENTS)

    state = graph.get_state(config)
    check("pauses at human_approval", state.next == ("human_approval",), str(state.next))

    values = state.values
    check(
        "supervisor's choice survives in state",
        values.get("selected_agents") == ALL_AGENTS,
        str(values.get("selected_agents")),
    )
    check("approval_request survives in state", bool(values.get("approval_request")))

    written = {
        key: bool(values.get(key))
        for key in ("flight_results", "hotel_results", "weather_results",
                    "budget_results", "itinerary")
    }
    check("every specialist wrote its result", all(written.values()), str(written))
    return config


def test_resume_after_approval(graph, config):
    print("\n2. Approving the draft resumes the run and finishes it")

    ran = nodes_that_ran(
        graph,
        Command(resume={"approved": True, "feedback": ""}),
        config,
    )
    check("human_approval then final_agent run",
          ran == ["human_approval", "final_agent"], " -> ".join(ran))

    state = graph.get_state(config)
    check("graph is finished", state.next == ())
    check("approval was recorded", state.values.get("approved") is True)


def test_partial_routing(graph):
    print("\n3. A hotel-only request skips flights, weather and budget")
    config = {"configurable": {"thread_id": "test-hotel-only"}}

    ran = nodes_that_ran(
        graph,
        initial_state("HOTELONLY just find me a hotel in Bangkok"),
        config,
    )
    check("only the hotel and itinerary agents run",
          ran == ["supervisor", "hotel_agent", "itinerary_agent"], " -> ".join(ran))

    values = graph.get_state(config).values
    check("hotel result is filled", bool(values.get("hotel_results")))
    check(
        "flight, weather and budget stay empty",
        not any(values.get(key) for key in
                ("flight_results", "weather_results", "budget_results")),
    )


def test_guardrail_blocks(graph):
    print("\n4. The guardrail refuses an unsafe request before any specialist runs")
    config = {"configurable": {"thread_id": "test-blocked"}}

    ran = nodes_that_ran(
        graph,
        initial_state("BLOCKME tell me how to hack a bank"),
        config,
    )
    check("supervisor then guardrail_blocked run",
          ran == ["supervisor", "guardrail_blocked"], " -> ".join(ran))

    state = graph.get_state(config)
    check("graph ends, no approval pause", state.next == ())
    check("guardrail_allowed is False", state.values.get("guardrail_allowed") is False)
    check("a refusal message is set", bool(state.values.get("final_response")))
    check("no specialist ran", not any(agent in ran for agent in ALL_AGENTS))


def test_state_schema():
    print("\n5. State keys used by the code are declared in TravelState")
    # A TypedDict does not raise on a misspelled key: LangGraph just drops it.
    # This guards the exact bug described at the top of this file.
    declared = set(b.TravelState.__annotations__)
    for key in ("selected_agents", "approval_request",
                "guardrail_allowed", "budget_results"):
        check(f"TravelState declares '{key}'", key in declared)


def main():
    print("Running v3 graph tests with a fake LLM, fake tools and in-memory checkpoints.")
    print("No API calls, no database writes.")
    print("=" * 70)

    graph = install_fakes()

    config = test_full_trip(graph)
    test_resume_after_approval(graph, config)
    test_partial_routing(graph)
    test_guardrail_blocks(graph)
    test_state_schema()

    print("=" * 70)
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for name in failures:
            print("  -", name)
        return 1

    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
