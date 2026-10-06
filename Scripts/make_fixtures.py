#!/usr/bin/env python3
"""Generate short, locally authored audiovisual fixtures (no external sites)."""
from pathlib import Path
import shutil, subprocess, re
root=Path(__file__).resolve().parents[1]
out=root/'Build/Fixtures'
out.mkdir(parents=True,exist_ok=True)
ffmpeg=shutil.which('ffmpeg')
if not ffmpeg: raise SystemExit('A full FFmpeg build is needed only to generate test fixtures.')
def run(*args): subprocess.run([ffmpeg,'-nostdin','-hide_banner','-loglevel','error','-y',*map(str,args)],check=True)
run('-f','lavfi','-i','testsrc2=size=426x240:rate=25','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','12','-c:v','libx264','-preset','ultrafast','-g','50','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart',out/'direct.mp4')
run('-i',out/'direct.mp4','-vn','-c:a','libmp3lame',out/'audio.mp3')
hls=out/'hls'; hls.mkdir(exist_ok=True)
run('-i',out/'direct.mp4','-c','copy','-hls_time','2','-hls_playlist_type','vod',hls/'single.m3u8')
run('-i',out/'direct.mp4','-vf','scale=256:144','-c:v','libx264','-preset','ultrafast','-g','50','-c:a','aac','-hls_time','2','-hls_playlist_type','vod',hls/'144.m3u8')
run('-i',out/'direct.mp4','-map','0:v','-c','copy','-hls_time','2','-hls_playlist_type','vod',hls/'video.m3u8')
run('-i',out/'direct.mp4','-map','0:a','-c','copy','-hls_time','2','-hls_playlist_type','vod',hls/'audio.m3u8')
(hls/'master.m3u8').write_text('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1100000,RESOLUTION=426x240,CODECS="avc1.42e01e,mp4a.40.2"\nsingle.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=700000,RESOLUTION=256x144,CODECS="avc1.42e01e,mp4a.40.2"\n144.m3u8\n')
(hls/'split.m3u8').write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Original",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=426x240,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="audio"\nvideo.m3u8\n')
dash=out/'dash'; dash.mkdir(exist_ok=True)
run('-i',out/'direct.mp4','-map','0:v','-map','0:a','-c','copy','-seg_duration','2','-use_timeline','1','-use_template','1','-f','dash',dash/'manifest.mpd')
(out/'protected.m3u8').write_text('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://fixture"\n#EXTINF:2,\nhls/single0.ts\n#EXT-X-ENDLIST\n')

# Standard AES-128 fixtures encrypted by OpenSSL, independently of the app's CommonCrypto decryptor.
openssl=shutil.which('openssl')
if not openssl: raise SystemExit('OpenSSL is required to generate AES-128 test fixtures.')
aes=out/'aes'; aes.mkdir(exist_ok=True)
def encrypt(source,destination,key,iv):
 subprocess.run([openssl,'enc','-aes-128-cbc','-K',key.hex(),'-iv',iv.hex(),'-in',str(source),'-out',str(destination)],check=True)
def encrypted_playlist(source,name,*,sequence=37,rotating=False,explicit=False,clear_last=False,by_range=False):
 lines=source.read_text().splitlines()
 media=[line for line in lines if line and not line.startswith('#')]
 folder=aes/name; folder.mkdir(exist_ok=True)
 result=['#EXTM3U',f'#EXT-X-MEDIA-SEQUENCE:{sequence}']
 index=0; active=None; packed=bytearray()
 for line in lines:
  if line.startswith(('#EXTM3U','#EXT-X-MEDIA-SEQUENCE')): continue
  if line.startswith('#EXT-X-MAP:'):
   original=re.search(r'URI="([^"]+)"',line)[1]
   key=bytes(range(16)); iv=(123).to_bytes(16,'big')
   (folder/'init.key').write_bytes(key)
   encrypt(source.parent/original,folder/'init.mp4',key,iv)
   result+=['#EXT-X-KEY:METHOD=AES-128,URI="init.key",IV=0x'+iv.hex(),'#EXT-X-MAP:URI="init.mp4"']
   continue
  if line.startswith('#') or not line:
   result.append(line); continue
  clear=clear_last and index==len(media)-1
  key_index=index//2 if rotating else 0
  key=bytes((value+key_index*17)%256 for value in range(16))
  iv=(123+index if explicit else sequence+index).to_bytes(16,'big')
  key_name=f'key{key_index}.bin'
  state=(key_name,iv if explicit else None,clear)
  if state!=active:
   result.append('#EXT-X-KEY:METHOD=NONE' if clear else f'#EXT-X-KEY:METHOD=AES-128,URI="{key_name}"'+(',IV=0x'+iv.hex() if explicit else ''))
   active=state
  (folder/key_name).write_bytes(key)
  filename=f'{index:03d}.chunk'
  if clear: shutil.copyfile(source.parent/line,folder/filename)
  else: encrypt(source.parent/line,folder/filename,key,iv)
  if by_range:
   data=(folder/filename).read_bytes()
   result+=[f'#EXT-X-BYTERANGE:{len(data)}@{len(packed)}','packed.bin']
   packed.extend(data)
  else: result.append(filename)
  index+=1
 if by_range: (folder/'packed.bin').write_bytes(packed)
 (folder/'index.m3u8').write_text('\n'.join(result)+'\n')

encrypted_playlist(hls/'single.m3u8','implicit')
encrypted_playlist(hls/'single.m3u8','slow',rotating=True)
encrypted_playlist(hls/'single.m3u8','explicit',explicit=True)
encrypted_playlist(hls/'single.m3u8','rotation',rotating=True,clear_last=True)
encrypted_playlist(hls/'single.m3u8','ranges',rotating=True,by_range=True)
encrypted_playlist(hls/'video.m3u8','video',rotating=True)
encrypted_playlist(hls/'audio.m3u8','audio',sequence=100,rotating=True)
(aes/'preview-scoped.m3u8').write_text('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:37\n#EXT-X-KEY:METHOD=AES-128,URI="video/key0.bin"\n#EXTINF:2,\nvideo/000.chunk\n#EXT-X-KEY:METHOD=AES-128,URI="video/key0.bin"\n#EXTINF:2,\nvideo/001.chunk\n#EXT-X-ENDLIST\n')
run('-i',out/'direct.mp4','-c','copy','-hls_time','2','-hls_playlist_type','vod','-hls_segment_type','fmp4','-hls_fmp4_init_filename','init.mp4',hls/'fmp4.m3u8')
encrypted_playlist(hls/'fmp4.m3u8','fmp4',rotating=True)
(aes/'master.m3u8').write_text('#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI="rotation/key0.bin"\n#EXT-X-STREAM-INF:BANDWIDTH=1100000,RESOLUTION=426x240,CODECS="avc1.42e01e,mp4a.40.2"\nrotation/index.m3u8\n')
(aes/'split.m3u8').write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Original",DEFAULT=YES,URI="audio/index.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=426x240,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="audio"\nvideo/index.m3u8\n')
(aes/'short.key').write_bytes(b'short')
(aes/'long.key').write_bytes(bytes(32))
for name,key_url in [('short','short.key'),('long','long.key'),('forbidden','/status/403'),('html','/html-error.mp4'),('corrupt','rotation/key0.bin')]:
 chunk='rotation/002.chunk' if name=='corrupt' else 'implicit/000.chunk'
 (aes/f'bad-{name}.m3u8').write_text(f'#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:37\n#EXT-X-KEY:METHOD=AES-128,URI="{key_url}"\n#EXTINF:2,\n{chunk}\n#EXT-X-ENDLIST\n')
pages={
 'mp4':'<video controls src="/direct.mp4"></video>',
 'audio':'<audio controls src="/audio.mp3"></audio>',
 'hls-master':'<video controls src="/hls/master.m3u8"></video>',
 'hls-single':'<video controls src="/hls/single.m3u8"></video>',
 'hls-split':'<video controls src="/hls/split.m3u8"></video>',
 'hls-aes':'<video controls src="/aes/master.m3u8"></video>',
 'hls-aes-audio':'<video controls src="/aes/split.m3u8"></video>',
 'dash':'<video controls id="video"></video><script>fetch("/dash/manifest.mpd").then(r=>r.text()).then(t=>document.querySelector("p").textContent="DASH 播放信息已读取；通过 SiftX 下载生成可播放文件。")</script>',
 'blob':'<video controls id="video"></video><script>fetch("/direct.mp4").then(r=>r.blob()).then(b=>video.src=URL.createObjectURL(b))</script>',
 'spa':'<button onclick="history.pushState({},\"\",\"?page=\"+Date.now());document.title=\"SPA 页面 \"+Date.now();video.src=\"/audio.mp3\"">切换页面为音频</button><video id="video" controls src="/direct.mp4"></video>',
 'protected':'<video controls src="/protected.m3u8"></video>',
}
for name,body in pages.items():
 (out/f'{name}.html').write_text(f'<!doctype html><html lang="zh"><meta charset="utf-8"><title>SiftX 测试 · {name}</title><style>body{{font:16px system-ui;max-width:760px;margin:60px auto}}video{{width:100%}}</style><h1>SiftX 本地媒体测试 · {name}</h1><p>所有资源均在本机生成，用于验证发现和下载。</p>{body}</html>')
(out/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>SiftX 测试媒体</title><h1>SiftX 测试媒体</h1>'+''.join(f'<p><a href="/{name}.html">{name}</a></p>' for name in pages))
print(out)
