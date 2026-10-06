#!/usr/bin/env python3
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import argparse, re, time, threading, json
from urllib.parse import urlsplit
parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=18765); parser.add_argument('--directory',default=str(Path(__file__).resolve().parents[1]/'Build/Fixtures'))
args=parser.parse_args(); truncated=set(); mutex=threading.Lock(); requests={}; referers={}
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw): super().__init__(*a,directory=args.directory,**kw)
 def log_message(self,*a): pass
 def do_HEAD(self): self.serve(True)
 def do_GET(self): self.serve(False)
 def serve(self,head):
  path=urlsplit(self.path).path
  if path=='/fixture-stats':
   with mutex: data=json.dumps({'requests':requests,'referers':referers}).encode()
   self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
   if not head: self.wfile.write(data)
   return
  with mutex:
   requests[path]=requests.get(path,0)+1
   referers[path]=self.headers.get('Referer','')
  if path in ['/html-error.mp4','/json-error.mp4']:
   data=b'<html>Sign in</html>' if path=='/html-error.mp4' else b'{"error":"login required"}'
   self.send_response(200); self.send_header('Content-Type','text/html' if path=='/html-error.mp4' else 'application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
   if not head: self.wfile.write(data)
   return
  if path.startswith('/status/'):
   status=int(path.split('/')[-1]); self.send_response(status); self.send_header('Content-Length','0'); self.end_headers(); return
  if path in ['/slow.mp4','/no-range.mp4','/truncated.mp4','/range-bad.mp4']: relative='direct.mp4'
  else: relative=path.lstrip('/') or 'index.html'
  target=(Path(args.directory)/relative).resolve()
  if not target.is_relative_to(Path(args.directory).resolve()) or not target.is_file(): self.send_error(404); return
  size=target.stat().st_size; start=0; end=size-1; status=200
  range_value=self.headers.get('Range')
  if range_value and path!='/no-range.mp4':
   match=re.fullmatch(r'bytes=(\d+)-(\d*)',range_value)
   if not match: self.send_error(416); return
   start=int(match[1]); end=min(int(match[2]) if match[2] else end,end)
   if start> end: self.send_response(416); self.send_header('Content-Range',f'bytes */{size}'); self.send_header('Content-Length','0'); self.end_headers(); return
   status=206
  self.send_response(status); self.send_header('Content-Type',self.guess_type(str(target))); self.send_header('Content-Length',str(end-start+1)); self.send_header('Accept-Ranges','bytes'); self.send_header('ETag','"siftx-fixture-v1"'); self.send_header('Access-Control-Allow-Origin','*')
  if status==206: self.send_header('Content-Range',f'bytes {start+1 if path=="/range-bad.mp4" else start}-{end}/{size}')
  self.end_headers()
  if head: return
  should_truncate=False
  with mutex:
   if path=='/truncated.mp4' and path not in truncated: truncated.add(path); should_truncate=True
  length=end-start+1
  if should_truncate: length//=2
  try:
   with target.open('rb') as stream:
    stream.seek(start)
    while length:
     data=stream.read(min(16384,length))
     if not data: break
     self.wfile.write(data); self.wfile.flush(); length-=len(data)
     if path in ['/slow.mp4','/no-range.mp4','/range-bad.mp4'] or path.startswith('/aes/slow/'): time.sleep(.08)
   if should_truncate: self.close_connection=True
  except (BrokenPipeError,ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
print(f'Fixtures at http://127.0.0.1:{server.server_port}',flush=True)
server.serve_forever()
