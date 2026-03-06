#!/usr/bin/env python3
import http.server
import json
import os
import subprocess
import socket
import random
from urllib.parse import urlparse, parse_qs

PORT = int(os.getenv("HEALTH_PORT", 8999))
API_KEY = os.getenv("API_KEY")

import time

import sys

def log_api(msg):
    print(f"[api] {msg}", file=sys.stderr, flush=True)

class VPNHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        log_api(format % args)

    def _send_response(self, status, data):
        try:
            log_api(f"Sending response {status}: {data}")
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')  # Ensure connection is closed cleanly
            self.end_headers()
            self.wfile.write(json.dumps(data).encode('utf-8'))
            log_api("Response sent successfully.")
        except Exception as e:
            log_api(f"Error sending response: {e}")

    def _check_auth(self):
        key = self.headers.get('X-API-KEY')
        log_api(f"Auth check: Key provided? {'Yes' if key else 'No'}")
        if not API_KEY:
            return True
        return key == API_KEY

    def _get_current_state(self):
        try:
            return subprocess.check_output(['expressvpnctl', 'get', 'connectionstate'], text=True).strip().lower()
        except Exception as e:
            log_api(f"Error getting state: {e}")
            return "error"

    def _wait_for_connection(self, timeout=30):
        """Polls until state is 'connected' or timeout expires."""
        start = time.time()
        while time.time() - start < timeout:
            if self._get_current_state() == 'connected':
                return True
            time.sleep(2)
        return False

    def do_GET(self):
        log_api(f"GET {self.path}")
        self._handle_request("GET")

    def do_POST(self):
        log_api(f"POST {self.path}")
        self._handle_request("POST")

    def _handle_request(self, method):
        try:
            if not self._check_auth():
                log_api("Unauthorized access attempt.")
                return self._send_response(401, {"error": "Unauthorized"})

            parsed_path = urlparse(self.path)
            
            # --- Status/Info Endpoints ---
            if parsed_path.path == '/health':
                state = self._get_current_state()
                status_bit = 200 if state == 'connected' else 503
                return self._send_response(status_bit, {"status": state})

            elif parsed_path.path == '/regions':
                regions = subprocess.check_output(['expressvpnctl', 'get', 'regions'], text=True).splitlines()
                us_regions = [r for r in regions if r.startswith('usa-')]
                return self._send_response(200, {"regions": us_regions})

            # --- Control Endpoints (Supported on both GET and POST) ---
            elif parsed_path.path == '/connect':
                params = parse_qs(parsed_path.query)
                region = params.get('region', [None])[0]
                if not region:
                    return self._send_response(400, {"error": "Missing region parameter"})
                
                log_api(f"Connecting to {region}...")
                subprocess.run(['expressvpnctl', 'connect', region], check=True)
                if self._wait_for_connection():
                    return self._send_response(200, {"message": f"Successfully connected to {region}"})
                else:
                    return self._send_response(504, {"error": f"Timed out waiting for connection to {region}"})

            elif parsed_path.path == '/rotate':
                MAX_RETRIES = 3
                regions_raw = subprocess.check_output(['expressvpnctl', 'get', 'regions'], text=True).splitlines()
                us_regions = [r for r in regions_raw if r.startswith('usa-')]
                if not us_regions:
                    return self._send_response(500, {"error": "No US regions found"})
                
                attempt = 0
                while attempt < MAX_RETRIES:
                    new_region = random.choice(us_regions)
                    log_api(f"Rotation attempt {attempt + 1}: trying {new_region}...")
                    
                    try:
                        subprocess.run(['expressvpnctl', 'connect', new_region], check=True)
                        if self._wait_for_connection(timeout=25):
                            log_api(f"Rotation successful: {new_region} connected.")
                            return self._send_response(200, {"message": f"Successfully rotated to {new_region}", "region": new_region})
                        else:
                            log_api(f"Timeout connecting to {new_region}. Retrying...")
                    except subprocess.CalledProcessError:
                        log_api(f"Execution error connecting to {new_region}. Retrying...")
                    
                    attempt += 1
                
                return self._send_response(504, {"error": "Failed to rotate after multiple attempts."})

            else:
                return self._send_response(404, {"error": "Not Found"})
        except Exception as e:
            log_api(f"Critical error in {method}: {e}")
            self._send_response(500, {"error": str(e)})

if __name__ == '__main__':
    log_api(f"Starting VPN Control API on port {PORT}...")
    if not API_KEY:
        log_api("WARNING: No API_KEY set. API is insecure!")
    
    server = http.server.HTTPServer(('0.0.0.0', PORT), VPNHandler)
    server.serve_forever()
