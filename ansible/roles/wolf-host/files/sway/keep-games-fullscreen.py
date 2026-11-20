#!/usr/bin/env python3
# Keeps Steam games fullscreen in Sway. Unity/Proton games can drop out of
# fullscreen when their resolution doesn't match the stream (e.g. >1080p),
# leaving Sway to tile them next to Big Picture (left half black).
# Started from custom-cfg. See homelab apps/wolf/README.md.
import json, subprocess

sub = subprocess.Popen(['swaymsg', '-r', '-m', '-t', 'subscribe', '["window"]'],
                       stdout=subprocess.PIPE, text=True)
dec = json.JSONDecoder()
buf = ''
for chunk in iter(lambda: sub.stdout.readline(), ''):
    buf += chunk
    while buf.strip():
        try:
            ev, end = dec.raw_decode(buf.lstrip())
        except ValueError:
            break
        buf = buf.lstrip()[end:]
        con = ev.get('container') or {}
        cls = (con.get('window_properties') or {}).get('class') or ''
        if cls.startswith('steam_app_') and con.get('fullscreen_mode') == 0                 and ev.get('change') in ('new', 'fullscreen_mode', 'title', 'focus'):
            subprocess.run(['swaymsg', '[con_id=%d] fullscreen enable, focus' % con['id']],
                           stdout=subprocess.DEVNULL)
