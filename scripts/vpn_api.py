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

class VPNHandler(http.server.BaseHTTPRequestHandler):
    def _send_response(self, status, data):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def _check_auth(self):
        if not API_KEY:
            return True
        key = self.headers.get('X-API-KEY')
        return key == API_KEY

    def _get_current_state(self):
        try:
            return subprocess.check_output(['expressvpnctl', 'get', 'connectionstate'], text=True).strip().lower()
        except:
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
        if not self._check_auth():
            return self._send_response(401, {"error": "Unauthorized"})

        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/health':
            state = self._get_current_state()
            status_bit = 200 if state == 'connected' else 503
            self._send_response(status_bit, {"status": state})

        elif parsed_path.path == '/regions':
            try:
                regions = subprocess.check_output(['expressvpnctl', 'get', 'regions'], text=True).splitlines()
                # Filter for US regions
                us_regions = [r for r in regions if r.startswith('usa-')]
                self._send_response(200, {"regions": us_regions})
            except Exception as e:
                self._send_response(500, {"error": str(e)})

        else:
            self._send_response(404, {"error": "Not Found"})

    def do_POST(self):
        if not self._check_auth():
            return self._send_response(401, {"error": "Unauthorized"})

        parsed_path = urlparse(self.path)

        if parsed_path.path == '/connect':
            params = parse_qs(parsed_path.query)
            region = params.get('region', [None])[0]
            if not region:
                return self._send_response(400, {"error": "Missing region parameter"})
            
            try:
                print(f"Connecting to {region}...")
                subprocess.run(['expressvpnctl', 'connect', region], check=True)
                if self._wait_for_connection():
                    self._send_response(200, {"message": f"Successfully connected to {region}"})
                else:
                    self._send_response(504, {"error": f"Timed out waiting for connection to {region}"})
            except subprocess.CalledProcessError as e:
                self._send_response(500, {"error": f"Failed to connect: {e}"})

        elif parsed_path.path == '/rotate':
            MAX_RETRIES = 3
            try:
                regions_raw = subprocess.check_output(['expressvpnctl', 'get', 'regions'], text=True).splitlines()
                us_regions = [r for r in regions_raw if r.startswith('usa-')]
                if not us_regions:
                    return self._send_response(500, {"error": "No US regions found"})
                
                attempt = 0
                while attempt < MAX_RETRIES:
                    new_region = random.choice(us_regions)
                    print(f"Rotation attempt {attempt + 1}: trying {new_region}...")
                    
                    try:
                        subprocess.run(['expressvpnctl', 'connect', new_region], check=True)
                        if self._wait_for_connection(timeout=25):
                            print(f"Rotation successful: {new_region} connected.")
                            return self._send_response(200, {"message": f"Successfully rotated to {new_region}", "region": new_region})
                        else:
                            print(f"Timeout connecting to {new_region}. Retrying...")
                    except subprocess.CalledProcessError:
                        print(f"Execution error connecting to {new_region}. Retrying...")
                    
                    attempt += 1
                
                self._send_response(504, {"error": "Failed to rotate after multiple attempts."})
            except Exception as e:
                self._send_response(500, {"error": str(e)})

        else:
            self._send_response(404, {"error": "Not Found"})

if __name__ == '__main__':
    print(f"Starting VPN Control API on port {PORT}...")
    if not API_KEY:
        print("WARNING: No API_KEY set. API is insecure!")
    
    server = http.server.HTTPServer(('0.0.0.0', PORT), VPNHandler)
    server.serve_forever()
