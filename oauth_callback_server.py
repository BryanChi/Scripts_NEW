import http.server
import socketserver
import urllib.parse
import os

PORT = 8080
CODE_FILE = r'/Users/b/Library/Application Support/REAPER/Scripts/BRYAN's SCRIPTS/oauth_callback_code.txt'

class CallbackHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/callback'):
            query = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(query)
            if 'code' in params:
                code = params['code'][0]
                # Write code to file for REAPER to read
                try:
                    with open(CODE_FILE, 'w') as f:
                        f.write(code)
                except:
                    pass
                
                # Send beautiful success page
                self.send_response(200)
                self.send_header('Content-type', 'text/html')
                self.end_headers()
                html = '''<!DOCTYPE html>
<html>
<head>
    <title>Authentication Successful</title>
    <meta charset="UTF-8">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .container {
            background: white;
            padding: 50px;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            max-width: 500px;
            text-align: center;
            animation: slideIn 0.5s ease-out;
        }
        @keyframes slideIn {
            from { opacity: 0; transform: translateY(-20px); }
            to { opacity: 1; transform: translateY(0); }
        }
        .checkmark {
            width: 80px;
            height: 80px;
            border-radius: 50%;
            background: #4CAF50;
            margin: 0 auto 30px;
            display: flex;
            align-items: center;
            justify-content: center;
            animation: scaleIn 0.5s ease-out 0.2s both;
        }
        @keyframes scaleIn {
            from { transform: scale(0); }
            to { transform: scale(1); }
        }
        .checkmark::after {
            content: '✓';
            color: white;
            font-size: 50px;
            font-weight: bold;
        }
        h1 {
            color: #333;
            font-size: 28px;
            margin-bottom: 15px;
        }
        p {
            color: #666;
            font-size: 16px;
            line-height: 1.6;
            margin-bottom: 10px;
        }
        .subtext {
            font-size: 14px;
            color: #999;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="checkmark"></div>
        <h1>Authentication Successful!</h1>
        <p>You have been successfully authenticated.</p>
        <p>You can safely close this window and return to REAPER.</p>
        <p class="subtext">The authorization has been automatically processed.</p>
    </div>
</body>
</html>'''
                self.wfile.write(html.encode())
                return
        self.send_response(404)
        self.end_headers()
    
    def log_message(self, format, *args):
        pass  # Suppress logs

try:
    with socketserver.TCPServer(("", PORT), CallbackHandler) as httpd:
        httpd.timeout = 120  # 2 minute timeout
        httpd.handle_request()  # Handle one request then exit
except:
    pass
