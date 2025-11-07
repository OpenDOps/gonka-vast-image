#!/usr/bin/env python3
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer

class HelloHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        message = "Hello world\n"
        body = message.encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return  # silence default logging

def main():
    parser = argparse.ArgumentParser(description="Simple Hello World HTTP server.")
    parser.add_argument(
        "--port", "-p", type=int, default=8080,
        help="Port to listen on (default: 8080)"
    )
    args = parser.parse_args()

    server = HTTPServer(("0.0.0.0", args.port), HelloHandler)
    print(f"Serving Hello World on port {args.port}…")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()

if __name__ == "__main__":
    main()