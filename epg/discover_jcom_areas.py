"""J:COM 番組表のエリア ID ごとの地上波チャンネルを調べる（一度だけ使う調査用）"""
import json
import re
import sys
import time
import urllib.request

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Cookie": "AD_NAV=1;"})
    with urllib.request.urlopen(req, timeout=20) as res:
        return res.read().decode("utf-8", "replace")


# トップページからエリア ID らしき値を拾う
try:
    html = get("https://tvguide.myjcom.jp/")
    print("homepage area hints:", sorted(set(re.findall(r"area(?:_id|Id)?[\"'=: ]+(\d{1,4})", html)))[:100])
except Exception as e:
    print("homepage error", e)

start, end = int(sys.argv[1]), int(sys.argv[2])
for area in range(start, end + 1):
    url = f"https://tvguide.myjcom.jp/api/mypage/getEpgChannelList/?channelType=2&area={area}&channelGenre&course&chart&is_adult=true"
    try:
        data = json.loads(get(url))
        items = data.get("header") or []
        names = [f'{i["channel_name"]}={i["channel_type"]}_{i["channel_id"]}_{i["network_id"]}' for i in items]
        if names:
            print(f"AREA {area}: " + " | ".join(names))
    except Exception as e:
        print(f"AREA {area}: error {e}")
    time.sleep(0.5)
