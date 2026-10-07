"""iptv-org/epg が出力した XMLTV に、リモコン番号を 2 つ目の <display-name> として追加する。

アプリは数字だけの display-name をチャンネル番号として使い、番号順に並べる。
番号が確かな局だけを書く（わからない局は番号なしで、ファイルの順に並ぶ）。
"""
import sys
import xml.etree.ElementTree as ET

REMOTE_NUMBERS = {
    "KBC.jp": 1,
    "RKB.jp": 4,
    "FBS.jp": 5,
    "TVQ.jp": 7,
    "TNC.jp": 8,
}

for path in sys.argv[1:]:
    tree = ET.parse(path)
    for channel in tree.getroot().findall("channel"):
        number = REMOTE_NUMBERS.get(channel.get("id"))
        if number is not None:
            names = channel.findall("display-name")
            element = ET.Element("display-name")
            element.text = str(number)
            channel.insert(len(names), element)
    tree.write(path, encoding="utf-8", xml_declaration=True)
    print(f"{path}: {len(tree.getroot().findall('channel'))} channels, {len(tree.getroot().findall('programme'))} programmes")
