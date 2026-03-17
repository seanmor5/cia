#!/usr/bin/env python3

import json
import os
import sys


def default_scenario():
    return {
        "account": {"id": "acct_test", "email": "fake@example.com"},
        "requires_openai_auth": False,
        "login_response": {"type": "apiKey"},
        "thread_ids": ["thread_test"],
        "turn_ids": ["turn_test"],
        "errors": {},
        "events": {},
        "exit_after": [],
    }


def deep_merge(left, right):
    if isinstance(left, dict) and isinstance(right, dict):
        merged = dict(left)
        for key, value in right.items():
            merged[key] = deep_merge(merged[key], value) if key in merged else value
        return merged
    return right


class FakeCodexServer:
    def __init__(self, scenario, trace_file=None):
        self.scenario = scenario
        self.trace_file = trace_file
        self.thread_counter = 0
        self.turn_counter = 0
        self.account = scenario.get("account")

    def run(self):
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue

            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.trace("unparsed_input", {"line": line})
                continue

            self.trace("received", message)
            if "id" in message:
                self.handle_request(message)
            else:
                self.handle_notification(message)

    def handle_request(self, message):
        method = message.get("method")
        request_id = message["id"]
        params = message.get("params") or {}

        error = self.error_for(method)
        if error is not None:
            self.send({"jsonrpc": "2.0", "id": request_id, "error": error})
            self.maybe_emit_events(method)
            self.maybe_exit(method)
            return

        result = self.result_for(method, params)
        self.send({"jsonrpc": "2.0", "id": request_id, "result": result})
        self.maybe_emit_events(method)
        self.maybe_exit(method)

    def handle_notification(self, message):
        method = message.get("method")
        self.trace("notification", message)
        self.maybe_emit_events(method)
        self.maybe_exit(method)

    def result_for(self, method, params):
        if method == "initialize":
            return {"serverInfo": {"name": "fake-codex", "version": "0.1.0"}}

        if method == "account/read":
            return {
                "account": self.account,
                "requiresOpenaiAuth": bool(self.scenario.get("requires_openai_auth", False)),
            }

        if method == "account/login/start":
            response = self.scenario.get("login_response") or {"type": "apiKey"}
            if response.get("type") in {"apiKey", "chatgptAuthTokens"}:
                self.account = self.account or {"id": "acct_logged_in", "email": "fake@example.com"}
            return response

        if method == "thread/start":
            thread_id = self.next_thread_id()
            return {"thread": {"id": thread_id}, "echo": params}

        if method == "thread/resume":
            thread_id = params.get("threadId") or self.next_thread_id()
            return {"thread": {"id": thread_id}, "echo": params}

        if method == "turn/start":
            turn_id = self.next_turn_id()
            return {"turn": {"id": turn_id}, "echo": params}

        if method == "turn/steer":
            return {"turnId": params.get("expectedTurnId")}

        if method == "turn/interrupt":
            return {"turnId": params.get("turnId"), "interrupted": True}

        return {}

    def error_for(self, method):
        errors = self.scenario.get("errors") or {}
        error = errors.get(method)
        if error is None:
            return None
        return {
            "code": error.get("code", -32000),
            "message": error.get("message", f"{method} failed"),
            "data": error.get("data"),
        }

    def maybe_emit_events(self, method):
        events = (self.scenario.get("events") or {}).get(method, [])
        for event in events:
            if "method" not in event:
                continue

            message = {"jsonrpc": "2.0", "method": event["method"]}
            if "params" in event:
                message["params"] = event["params"]
            self.send(message)

    def maybe_exit(self, method):
        if method in set(self.scenario.get("exit_after") or []):
            sys.exit(0)

    def next_thread_id(self):
        thread_ids = self.scenario.get("thread_ids") or []
        if self.thread_counter < len(thread_ids):
            thread_id = thread_ids[self.thread_counter]
        else:
            thread_id = f"thread_{self.thread_counter + 1}"
        self.thread_counter += 1
        return thread_id

    def next_turn_id(self):
        turn_ids = self.scenario.get("turn_ids") or []
        if self.turn_counter < len(turn_ids):
            turn_id = turn_ids[self.turn_counter]
        else:
            turn_id = f"turn_{self.turn_counter + 1}"
        self.turn_counter += 1
        return turn_id

    def send(self, payload):
        encoded = json.dumps(payload)
        sys.stdout.write(encoded + "\n")
        sys.stdout.flush()
        self.trace("sent", payload)

    def trace(self, direction, payload):
        if not self.trace_file:
            return

        with open(self.trace_file, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"direction": direction, "payload": payload}) + "\n")


def main():
    scenario, trace_file = parse_args(sys.argv[1:])

    scenario_json = os.environ.get("CIA_FAKE_CODEX_SCENARIO")
    if scenario_json:
        scenario = deep_merge(scenario, json.loads(scenario_json))

    trace_file = trace_file or os.environ.get("CIA_FAKE_CODEX_TRACE_FILE")
    FakeCodexServer(scenario, trace_file=trace_file).run()


def parse_args(argv):
    scenario = default_scenario()
    trace_file = None
    index = 0

    while index < len(argv):
        arg = argv[index]

        if arg == "--scenario":
            scenario = deep_merge(scenario, json.loads(argv[index + 1]))
            index += 2
            continue

        if arg == "--trace-file":
            trace_file = argv[index + 1]
            index += 2
            continue

        raise SystemExit(f"unknown argument: {arg}")

    return scenario, trace_file


if __name__ == "__main__":
    main()
