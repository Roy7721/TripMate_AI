# from tools.tavily_tool import tavily_search

# result = tavily_search("capital of bangladesh")

# print(result)

# from tools.flight_tool import search_flights

# print(search_flights("Plan a 7 days Japan trip from Bangladesh"))
# print("\n" + "=" * 80 + "\n")
# print(search_flights("all country flight info"))

from backend import run_travel_agent

user_input = input("Salam Boss. GIve me a try please.")


res = run_travel_agent(user_input = user_input, thread_id = 'testing')
print("HI")
print(res['answer'])