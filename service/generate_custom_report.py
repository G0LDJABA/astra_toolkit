import sys
import os
import xml.etree.ElementTree as ET
import html
import uuid
from datetime import datetime

# Helper to strip namespaces
def localname(tag):
    return tag.split("}")[-1] if "}" in tag else tag

def format_version(version_el):
    if version_el is None:
        return ""
    epoch = version_el.get("epoch")
    version = version_el.get("version") or version_el.text or ""
    release = version_el.get("release")
    
    epoch_str = f"{epoch}:" if epoch else ""
    release_str = f"-{release}" if release else ""
    return f"{epoch_str}{version}{release_str}".strip()

def main():
    if len(sys.argv) < 5:
        print("Usage: python generate_custom_report.py <definitions_xml> <results_xml> <output_html> <start_time>")
        sys.exit(1)
        
    definitions_xml = sys.argv[1]
    results_xml = sys.argv[2]
    output_html = sys.argv[3]
    start_time_str = sys.argv[4]
    
    print(f"Loading definitions from {definitions_xml}...")
    definitions = {}
    tests = {}
    
    # 1. Parse definitions XML
    context = ET.iterparse(definitions_xml, events=("start", "end"))
    context = iter(context)
    event, root = next(context)
    
    for event, elem in context:
        if event == "end":
            tag = localname(elem.tag)
            if tag == "definition":
                def_id = elem.get("id")
                def_class = elem.get("class")
                if def_class == "vulnerability":
                    metadata = elem.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}metadata")
                    title = ""
                    description = ""
                    severity = "Не определено"
                    remediation = ""
                    cpe_list = []
                    ref_list = []
                    
                    if metadata is not None:
                        title_el = metadata.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}title")
                        if title_el is not None:
                            title = title_el.text or ""
                        
                        desc_el = metadata.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}description")
                        if desc_el is not None:
                            description = desc_el.text or ""
                        
                        affected = metadata.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}affected")
                        if affected is not None:
                            for child in affected:
                                ctag = localname(child.tag)
                                if ctag in ("platform", "product", "cpe"):
                                    cpe_list.append(child.text or "")
                        
                        for ref in metadata.findall("{http://oval.mitre.org/XMLSchema/oval-definitions-5}reference"):
                            ref_list.append({
                                "source": ref.get("source", ""),
                                "ref_id": ref.get("ref_id", ""),
                                "ref_url": ref.get("ref_url", "")
                            })
                        
                        bdu = metadata.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}bdu")
                        if bdu is not None:
                            sev_el = bdu.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}severity")
                            if sev_el is not None:
                                severity = sev_el.text or "Не определено"
                                if severity == "Нет":
                                    severity = "Низкий"
                            rem_el = bdu.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}remediation")
                            if rem_el is not None:
                                remediation = rem_el.text or ""
                    
                    # Extract criteria tests
                    criteria_tests = []
                    criteria = elem.find("{http://oval.mitre.org/XMLSchema/oval-definitions-5}criteria")
                    if criteria is not None:
                        def get_test_refs(node):
                            refs = []
                            for child in node:
                                ctag = localname(child.tag)
                                if ctag == "criterion":
                                    tref = child.get("test_ref")
                                    if tref:
                                        refs.append(tref)
                                elif ctag == "criteria":
                                    refs.extend(get_test_refs(child))
                            return refs
                        criteria_tests = get_test_refs(criteria)
                    
                    definitions[def_id] = {
                        "title": title,
                        "description": description,
                        "severity": severity.strip(),
                        "remediation": remediation.strip(),
                        "cpe_list": cpe_list,
                        "ref_list": ref_list,
                        "criteria_tests": criteria_tests
                    }
                root.clear()
            
            elif tag.endswith("_test"):
                test_id = elem.get("id")
                obj_el = next((child for child in elem if localname(child.tag) == "object"), None)
                if obj_el is not None:
                    tests[test_id] = obj_el.get("object_ref", "")
                root.clear()

    # 2. Parse results XML
    print(f"Loading results from {results_xml}...")
    vulnerable_definitions = set()
    triggered_tests = set()
    obj_to_items = {}
    item_to_package = {}
    hostname = "unknown"
    report_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    context = ET.iterparse(results_xml, events=("start", "end"))
    context = iter(context)
    event, root = next(context)
    
    for event, elem in context:
        if event == "end":
            tag = localname(elem.tag)
            
            # Extract system info
            if tag == "primary_host_name":
                hostname = elem.text or hostname
                
            elif tag == "timestamp":
                # Look for generator timestamp if available
                report_time_parsed = elem.text
                if report_time_parsed:
                    # Convert to standard format
                    try:
                        dt = datetime.strptime(report_time_parsed.split(".")[0].strip(), "%Y-%m-%dT%H:%M:%S")
                        report_time = dt.strftime("%Y-%m-%d %H:%M:%S")
                    except Exception:
                        pass
                        
            # Extract results status
            elif tag == "definition" and elem.get("result") == "true":
                vulnerable_definitions.add(elem.get("definition_id"))
                
            elif tag == "test" and elem.get("result") == "true":
                triggered_tests.add(elem.get("test_id"))
                
            # Extract system characteristics
            elif tag == "object" and elem.get("id"):
                obj_id = elem.get("id")
                item_refs = [child.get("item_ref") for child in elem if localname(child.tag) == "reference"]
                if item_refs:
                    obj_to_items[obj_id] = item_refs
                    
            elif tag.endswith("_item") and elem.get("id"):
                item_id = elem.get("id")
                name_el = next((child for child in elem if localname(child.tag) == "name"), None)
                version_el = next((child for child in elem if localname(child.tag) == "version"), None)
                
                pkg_name = name_el.text if name_el is not None else ""
                pkg_ver = format_version(version_el)
                if pkg_name:
                    item_to_package[item_id] = f"{pkg_name} ({pkg_ver})"
            root.clear()

    # 3. Process severity counts
    severity_totals = {"Критический": 0, "Высокий": 0, "Средний": 0, "Низкий": 0, "Не определено": 0}
    severity_founds = {"Критический": 0, "Высокий": 0, "Средний": 0, "Низкий": 0, "Не определено": 0}
    
    for def_id, info in definitions.items():
        sev = info["severity"]
        if sev in severity_totals:
            severity_totals[sev] += 1
        else:
            severity_totals["Не определено"] += 1
            
        if def_id in vulnerable_definitions:
            if sev in severity_founds:
                severity_founds[sev] += 1
            else:
                severity_founds["Не определено"] += 1

    # 4. Generate report details
    found_vulnerabilities = []
    
    # Sort definitions to keep order consistent
    sorted_def_ids = list(definitions.keys())
    
    for def_id in sorted_def_ids:
        if def_id not in vulnerable_definitions:
            continue
            
        info = definitions[def_id]
        
        # Get triggering packages
        trigger_pkgs = []
        for tref in info["criteria_tests"]:
            if tref in triggered_tests:
                obj_ref = tests.get(tref)
                if obj_ref:
                    item_refs = obj_to_items.get(obj_ref, [])
                    for iref in item_refs:
                        pkg_str = item_to_package.get(iref)
                        if pkg_str and pkg_str not in trigger_pkgs:
                            trigger_pkgs.append(pkg_str)
                            
        # Get BDU ID from references
        bdu_id = ""
        for ref in info["ref_list"]:
            ref_id = ref["ref_id"]
            if ref["source"] == "FSTEC" or ref_id.startswith("BDU:"):
                bdu_id = ref_id
                break
        if not bdu_id:
            for ref in info["ref_list"]:
                if "BDU:" in ref["ref_id"]:
                    bdu_id = ref["ref_id"]
                    break
        if not bdu_id:
            bdu_id = def_id
            
        found_vulnerabilities.append({
            "bdu_id": bdu_id,
            "severity": info["severity"],
            "title": info["title"],
            "cpe_list": info["cpe_list"],
            "trigger_pkgs": trigger_pkgs,
            "def_id": def_id
        })

    # Generate HTML content
    print("Generating report HTML...")
    logo_base64 = (
        "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"
    )
    report_uuid = str(uuid.uuid4())
    scan_uuid = str(uuid.uuid4())
    
    # Severity CSS mapping
    severity_css = {
        "Критический": "risk-4",
        "Высокий": "risk-3",
        "Средний": "risk-2",
        "Низкий": "risk-1",
        "Не определено": "risk-0"
    }
    
    html_lines = []
    html_lines.append("<!doctype html><html lang='en'><head><meta charset='utf-8'><title>Отчёт</title>")
    html_lines.append("<style>* {padding: 0;margin: 0;border: 0;font: inherit;background: transparent;text-decoration: none;box-sizing: border-box;}html {background: #fafafa;display: flex;flex-direction: column;align-items: center;}body {flex: 1 0 0;width: 210mm;min-height: 297mm;background: white;font: 12px/12px Arial;}table {width: 100%;}th {background: #f0f0f0;text-align: left;vertical-align: top;padding: 5px 10px;}td {text-align: left;vertical-align: top;padding: 5px 10px;}.risk-0 {padding: 3px 5px;}.risk-1 {background-color: #00705C;color: white;padding: 3px 5px;}.risk-2 {background-color: #F5770F;color: white;padding: 3px 5px;}.risk-3 {background-color: #CC0000;color: white;padding: 3px 5px;}.risk-4 {background-color: #89171A;color: white;padding: 3px 5px;}.header {display: flex;flex-direction: row;justify-content: space-between;align-items: center;background: #fafafa;padding: 10px 0;}.header span {text-transform: uppercase;padding-right: 10px;}.report table th {width: 50%;}.report table td {background: #EFF4FB;}.summary {margin-top: 1cm;}.summary th {text-align: center;}.summary th:first-child {width: 50%;}.summary th:last-child {width: 25%;}.summary td {background: transparent;text-align: center;}.summary td:first-child {padding: 2px 0;}.summary span {display: inline-block;width: 33%;text-align: center;}.summary tr:last-child td {background: #EFF4FB;}.risk-found {margin-top: 1cm;}.risk-found th {text-align: center;white-space: nowrap;}.risk-found td span.risk-0,.risk-found td span.risk-1,.risk-found td span.risk-2,.risk-found td span.risk-3,.risk-found td span.risk-4 {display: inline-block;width: 100%;text-align: center;}.risk-found td:nth-child(2) {padding: 2px 0;}.risk-found td:first-child {text-align: center;}.risk-found td:last-child span:last-child {color: #777;}.risk-input {margin-top: 1cm;}.risk-input th {width: 25%;text-align: center;vertical-align: middle;padding: 10px 10px;}.risk-input td {padding: 10px 10px;}.risk-input tr:nth-child(2) td {background: #EFF4FB;}</style>")
    html_lines.append(f"</head><body><div class='header'><img alt='Logo' src='data:image/png;base64,{logo_base64}' /><span>Отчёт</span></div>")
    
    # 1. Report info table
    html_lines.append("<div class='report'><table>")
    html_lines.append(f"<tr><th>№ отчёта</th><td>{report_uuid}</td></tr>")
    html_lines.append(f"<tr><th>№ сканирования</th><td>{scan_uuid}</td></tr>")
    html_lines.append("<tr><th>Профиль</th><td>Уязвимости</td></tr>")
    html_lines.append(f"<tr><th>Начало сканирования</th><td>{start_time_str}</td></tr>")
    html_lines.append(f"<tr><th>Формирование отчета</th><td>{report_time}</td></tr>")
    html_lines.append("</table></div>")
    
    # 2. Summary stats table
    html_lines.append("<div class='summary'><table>")
    html_lines.append("<tr><th>Уровень опасности</th><th>Найдено</th><th>Всего</th></tr>")
    for s_name in ["Критический", "Высокий", "Средний", "Низкий", "Не определено"]:
        css_cls = severity_css.get(s_name, "risk-0")
        f_cnt = severity_founds.get(s_name, 0)
        t_cnt = severity_totals.get(s_name, 0)
        html_lines.append(f"<tr><td><span class='{css_cls}'>{s_name}</span></td><td>{f_cnt}</td><td>{t_cnt}</td></tr>")
    # Total row
    t_f = sum(severity_founds.values())
    t_t = sum(severity_totals.values())
    html_lines.append(f"<tr><td>Всего</td><td>{t_f}</td><td>{t_t}</td></tr>")
    html_lines.append("</table></div>")
    
    # 3. Found vulnerabilities table
    html_lines.append("<div class='risk-found'><table>")
    html_lines.append("<tr><th>Идентификатор</th><th>Уровень опасности</th><th>Название уязвимости</th></tr>")
    for f_item in found_vulnerabilities:
        css_cls = severity_css.get(f_item["severity"], "risk-0")
        bdu_id = html.escape(f_item["bdu_id"])
        title = html.escape(f_item["title"])
        cpes = ", ".join(f_item["cpe_list"])
        pkgs = ", ".join(f_item["trigger_pkgs"])
        
        cpe_str = f"<br><span>{html.escape(cpes)}</span>" if cpes else ""
        pkg_str = f"<br><span>{html.escape(pkgs)}</span>" if pkgs else ""
        
        html_lines.append(
            f"<tr><td>{bdu_id}</td>"
            f"<td><span class='{css_cls}'>{f_item['severity']}</span></td>"
            f"<td><span>{title}</span>{cpe_str}{pkg_str}</td></tr>"
        )
    html_lines.append("</table></div>")
    
    # 4. Detailed tables for all definitions
    html_lines.append("<div class='risk-input'>")
    for def_id in sorted_def_ids:
        info = definitions[def_id]
        
        # Get BDU ID
        bdu_id = ""
        for ref in info["ref_list"]:
            ref_id = ref["ref_id"]
            if ref["source"] == "FSTEC" or ref_id.startswith("BDU:"):
                bdu_id = ref_id
                break
        if not bdu_id:
            for ref in info["ref_list"]:
                if "BDU:" in ref["ref_id"]:
                    bdu_id = ref["ref_id"]
                    break
        if not bdu_id:
            bdu_id = def_id
            
        css_cls = severity_css.get(info["severity"], "risk-0")
        
        # Format sources
        ref_strs = []
        for ref in info["ref_list"]:
            source = html.escape(ref["source"])
            ref_id = html.escape(ref["ref_id"])
            ref_url = html.escape(ref["ref_url"])
            ref_strs.append(f"{source} <a href='{ref_url}'>{ref_id}</a>")
        ref_line = ", ".join(ref_strs)
        
        desc = html.escape(info["description"])
        rem = html.escape(info["remediation"])
        title = html.escape(info["title"])
        
        html_lines.append("<table>")
        html_lines.append(f"<tr><th class='{css_cls}'>Уязвимость</th><td>Уровень опасности: {info['severity']}</td></tr>")
        html_lines.append(f"<tr><th>{html.escape(bdu_id)}</th><td>{title}</td></tr>")
        html_lines.append(f"<tr><th>Описание уязвимости</th><td>{desc}</td></tr>")
        html_lines.append(f"<tr><th>Возможные меры по устранению уязвимости</th><td>{rem}</td></tr>")
        html_lines.append(f"<tr><th>Ссылки на источники</th><td>{ref_line}</td></tr>")
        html_lines.append("</table>")
        
    html_lines.append("</div></body></html>")
    
    # Write to output file
    print(f"Saving identical HTML report to {output_html}...")
    with open(output_html, "w", encoding="utf-8") as f:
        f.write("".join(html_lines))
    print("Done.")

if __name__ == "__main__":
    main()
