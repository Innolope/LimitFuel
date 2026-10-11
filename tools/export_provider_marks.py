"""Developer-only vector export for the checked-in SVG paths (requires reportlab)."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from reportlab.pdfgen import canvas

for source in (Path(__file__).resolve().parents[1] / "app/Assets").glob("*Mark.svg"):
    root = ET.parse(source).getroot()
    left, top, width, height = map(float, root.attrib["viewBox"].split())
    pdf = canvas.Canvas(str(source.with_suffix(".pdf")), pagesize=(width, height), invariant=1)
    pdf.translate(-left, height + top)
    pdf.scale(1, -1)
    for element in root.iter():
        if not element.tag.endswith("path"):
            continue
        tokens = re.findall(r"[MmLlHhVvCcZz]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", element.attrib["d"])
        path = pdf.beginPath()
        x = y = start_x = start_y = 0
        index = 0
        command = None
        while index < len(tokens):
            if tokens[index].isalpha():
                command = tokens[index]
                index += 1
            operation = command.upper()
            if operation == "Z":
                path.close()
                x, y = start_x, start_y
                command = None
                continue
            count = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6}[operation]
            values = list(map(float, tokens[index:index + count]))
            index += count
            if command.islower():
                values = [v + (y if operation == "V" or (operation not in ("H", "V") and i % 2) else x)
                          for i, v in enumerate(values)]
            if operation == "H": values = [values[0], y]
            if operation == "V": values = [x, values[0]]
            if operation == "M":
                path.moveTo(*values)
                start_x, start_y = values
                command = "l" if command.islower() else "L"
            elif operation == "C": path.curveTo(*values)
            else: path.lineTo(*values)
            x, y = values[-2:]
        pdf.drawPath(path, stroke=0, fill=1, fillMode=1)
    pdf.showPage()
    pdf.save()
