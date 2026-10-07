"""J:COM 番組表（tvguide.myjcom.jp）から地域ごとの番組表を XMLTV で作る。

    python3 epg/grab_jcom.py epg/channels.json out/ [日数]

XMLTV の標準の項目に加えて、テレビへの録画予約に使う ARIB の番号を属性で入れる
（XMLTV を読むほかのソフトは知らない属性を無視する）。

    <channel id="KBC.jp" broadcast="terrestrial" service-id="56336" network-id="31874">
      <display-name>KBC九州朝日</display-name>
      <display-name>1</display-name>            ← リモコン番号
    </channel>
    <programme start="20261007234500 +0900" stop="…" channel="KBC.jp"
               broadcast="terrestrial" service-id="56336" event-id="3528">
"""
import datetime
import json
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
BASE = "https://tvguide.myjcom.jp"
JST = datetime.timezone(datetime.timedelta(hours=9))
BROADCAST = {"2": "terrestrial", "3": "bs", "5": "cs", "120": "bs"}
GENRES = ["ニュース／報道", "スポーツ", "情報／ワイドショー", "ドラマ", "音楽", "バラエティ", "映画",
          "アニメ／特撮", "ドキュメンタリー／教養", "劇場／公演", "趣味／教育", "福祉"]


def fetch(site_id, date):
    key = f"{site_id}_{date:%Y%m%d}"
    req = urllib.request.Request(f"{BASE}/api/getEpgInfo/?channels={key}&rectime=&rec4k=",
                                 headers={"User-Agent": UA, "Cookie": "AD_NAV=1;"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                return json.loads(res.read()).get(key) or []
        except Exception as error:  # 一時的な失敗は少し待って取り直す
            print(f"  {key}: {error}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    return []


def xmltv_time(value):
    return datetime.datetime.strptime(str(value), "%Y%m%d%H%M%S").strftime("%Y%m%d%H%M%S +0900")


def genre(sort_genre):
    try:
        index = int(str(sort_genre)[0], 16)
    except (ValueError, IndexError):
        return None
    return GENRES[index] if index < len(GENRES) else None


def build(channels, days):
    tv = ET.Element("tv", {"generator-info-name": "firstrepo/epg/grab_jcom.py", "source-info-url": BASE})
    programmes = []
    today = datetime.datetime.now(JST).date()
    for channel in channels:
        channel_type, service_id, network_id = channel["site_id"].split("_")
        broadcast = BROADCAST.get(channel_type, "terrestrial")
        items = []
        for offset in range(-1, days):  # 前日分から取る（深夜 0〜5 時の番組は前日の番組表に入っている）
            items += fetch(channel["site_id"], today + datetime.timedelta(days=offset))
            time.sleep(1)  # サイトに負担をかけないよう 1 秒ずつ空ける

        name = next((i.get("channelName") for i in items if i.get("channelName")), channel["id"])
        number = next((i.get("digitalNo") for i in items if i.get("digitalNo")), None)
        element = ET.SubElement(tv, "channel", {"id": channel["id"], "broadcast": broadcast,
                                                "service-id": service_id, "network-id": network_id})
        ET.SubElement(element, "display-name").text = name
        if number:
            ET.SubElement(element, "display-name").text = str(number)

        seen = set()
        for item in items:
            key = (item.get("programStart"), item.get("eventId"))
            if not item.get("title") or not item.get("programStart") or not item.get("programEnd") or key in seen:
                continue
            seen.add(key)
            attributes = {"start": xmltv_time(item["programStart"]), "stop": xmltv_time(item["programEnd"]),
                          "channel": channel["id"], "broadcast": broadcast, "service-id": service_id}
            if str(item.get("eventId") or "").isdigit():
                attributes["event-id"] = str(int(item["eventId"]))
            programme = ET.Element("programme", attributes)
            ET.SubElement(programme, "title", {"lang": "ja"}).text = item["title"]
            if item.get("commentary"):
                ET.SubElement(programme, "desc", {"lang": "ja"}).text = item["commentary"]
            if genre(item.get("sortGenre")):
                ET.SubElement(programme, "category", {"lang": "ja"}).text = genre(item.get("sortGenre"))
            if item.get("imgPath"):
                ET.SubElement(programme, "icon", {"src": BASE + item["imgPath"]})
            programmes.append(programme)
        print(f"  {channel['id']} {name}: {len(seen)} programmes")
    tv.extend(programmes)
    return ET.ElementTree(tv)


def main():
    config_path, out_dir = sys.argv[1], sys.argv[2]
    days = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)
    failed = False
    for region, channels in config.items():
        if region.startswith("_"):
            continue
        print(region)
        tree = build(channels, days)
        if not tree.getroot().findall("programme"):
            print(f"  {region}: no programmes", file=sys.stderr)
            failed = True
            continue
        ET.indent(tree)
        tree.write(f"{out_dir}/guide-{region}.xml", encoding="utf-8", xml_declaration=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
