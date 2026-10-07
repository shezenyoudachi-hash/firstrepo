"""J:COM の番組データにどんな項目があるかを調べる（一度だけ使う調査用）"""
import datetime
import json
import urllib.request

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
date = (datetime.datetime.utcnow() + datetime.timedelta(hours=9)).strftime("%Y%m%d")
key = f"2_56336_31874_{date}"  # KBC
req = urllib.request.Request(
    f"https://tvguide.myjcom.jp/api/getEpgInfo/?channels={key}&rectime=&rec4k=",
    headers={"User-Agent": UA, "Cookie": "AD_NAV=1; area_id=37;"},
)
data = json.loads(urllib.request.urlopen(req, timeout=20).read())
items = data.get(key) or []
print("count", len(items))
for item in items[:3]:
    print(json.dumps(item, ensure_ascii=False, indent=1)[:3000])
