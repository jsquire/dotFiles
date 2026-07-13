---
name: office
description: Create and edit Office documents (Word .docx, PowerPoint .pptx, Excel .xlsx) by writing and running small Python scripts with python-docx, python-pptx, and openpyxl. Use whenever the user asks to author, generate, or edit a Word/PowerPoint/Excel file. Preferred over any MCP document tools — it costs almost no context.
---

# Office Documents (code-generation approach)

Author and edit `.docx`, `.pptx`, and `.xlsx` files by **writing a short Python script and running
it**. Do NOT ask for a document-editing tool — you already have a shell. The libraries
(`python-docx`, `python-pptx`, `openpyxl`) are well known to you from training; write ordinary Python.

## How to run

Run scripts with `uv`, which supplies the libraries on demand (no venv to manage, wheels are cached):

```
uv run --with python-docx --with python-pptx --with openpyxl <script>.py
```

- Use only the `--with` packages you actually need (e.g. just `--with python-docx` for a Word file).
- Write the script to a real file (e.g. `build_doc.py`) and run it; don't rely on huge inline one-liners.
- After running, confirm the output file exists and report its path to the user.

## Workflow

1. Clarify the target: file type, filename/path, and the content/structure requested.
2. Write a focused Python script that builds (or opens + edits) the document.
3. Run it with the `uv run --with ...` command above.
4. Verify the file was created/modified; surface any traceback and fix, then re-run.
5. Tell the user the final path (and a one-line summary of what you produced).

## Word — python-docx

```python
from docx import Document
from docx.shared import Pt, Inches

doc = Document()                      # or Document("existing.docx") to edit
doc.add_heading("Title", level=0)
doc.add_heading("Section", level=1)
p = doc.add_paragraph("Body text. ")
p.add_run("Bold.").bold = True
doc.add_paragraph("Bullet", style="List Bullet")
table = doc.add_table(rows=1, cols=2)
table.style = "Light Grid Accent 1"
table.rows[0].cells[0].text = "A"; table.rows[0].cells[1].text = "B"
doc.save("out.docx")
```

## PowerPoint — python-pptx

```python
from pptx import Presentation
from pptx.util import Inches, Pt

prs = Presentation()                  # or Presentation("existing.pptx") to edit
title = prs.slides.add_slide(prs.slide_layouts[0])
title.shapes.title.text = "Deck Title"
title.placeholders[1].text = "Subtitle"
body = prs.slides.add_slide(prs.slide_layouts[1])
body.shapes.title.text = "Agenda"
tf = body.placeholders[1].text_frame
tf.text = "First point"
tf.add_paragraph().text = "Second point"
prs.save("out.pptx")
```

## Excel — openpyxl

```python
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font

wb = Workbook()                       # or load_workbook("existing.xlsx") to edit
ws = wb.active; ws.title = "Sheet1"
ws.append(["Name", "Value"])
ws["A1"].font = Font(bold=True); ws["B1"].font = Font(bold=True)
ws.append(["Alpha", 10]); ws.append(["Beta", 20])
ws["B4"] = "=SUM(B2:B3)"
wb.save("out.xlsx")
```

## Notes

- To edit an existing file, open it (`Document(path)` / `Presentation(path)` / `load_workbook(path)`),
  modify, and save — overwrite the same path unless the user wants a copy.
- For images, use `doc.add_picture(path, width=Inches(...))` / `slide.shapes.add_picture(...)`.
- Keep scripts small and readable; iterate (run → read traceback → fix) rather than guessing large scripts.
- This approach works on every model/context size because it adds no tool schemas.
