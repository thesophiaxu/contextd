"""CLI entry point: ``python -m claude_proxy``."""

import argparse

from claude_proxy.server import DEFAULT_PORT, main

parser = argparse.ArgumentParser(description="Claude -p LLM proxy server")
parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Listen port")
main(port=parser.parse_args().port)
