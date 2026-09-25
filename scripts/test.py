# from tools.tavily_tool import tavily_search

# result = tavily_search("capital of bangladesh")

# print(result)

# from tools.flight_tool import search_flights

# print(search_flights("Plan a 7 days Japan trip from Bangladesh"))
# print("\n" + "=" * 80 + "\n")
# print(search_flights("all country flight info"))

# from backend import run_travel_agent

# user_input = input("Salam Boss. GIve me a try please.")


# res = run_travel_agent(user_input = user_input, thread_id = 'testing')
# print("HI")
# print(res['answer'])

import sys
import asyncio
from pathlib import Path

# mcp_client now lives in v2/, so make that folder importable from here
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "v2"))

from mcp_client import get_all_tools

if __name__ =="__main__":
    asyncio.run(get_all_tools())

# import asyncio
# from mcp_client_test import tavily_mcp_search

# if __name__ =="__main__":
#     query = "who is the winner of fifa world cup 2022."
#     result = asyncio.run(tavily_mcp_search(query))
#     print(result)
