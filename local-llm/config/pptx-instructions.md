# PowerPoint Editing Guide (ppt-mcp)

ppt-mcp controls a live PowerPoint instance via COM automation (154 tools).

## Workflow
1. Open file in PowerPoint
2. `ppt_activate_presentation` (CALL FIRST!)
3. Edit using tools below
4. `ppt_save_presentation`

## Essential Tools
- `ppt_activate_presentation` — lock session to a file (required first step)
- `ppt_find_replace_text` — find and replace across deck or slide
- `ppt_set_text` / `ppt_get_text` / `ppt_get_all_text` — text operations
- `ppt_get_slide_info` / `ppt_list_slides` — inspect structure
- `ppt_add_slide` / `ppt_delete_slide` — slide management
- `ppt_save_presentation` / `ppt_save_presentation_as` — save (export to PDF/PNG)

## Advanced Tools
- **Charts**: `ppt_add_chart` (20+ types: column, bar, line, pie, scatter, area, doughnut, radar) → `ppt_set_chart_data` → `ppt_format_chart`
- **SmartArt**: `ppt_add_smartart` (Process, Org Chart, Cycle, Funnel, Venn, Timeline) → `ppt_modify_smartart`
- **Tables**: `ppt_add_table` → `ppt_set_table_data` → `ppt_merge_table_cells` → `ppt_set_table_borders`
- **Themes**: `ppt_set_theme_colors` (17 presets or auto-generate from brand color)
- **Animations**: `ppt_add_animation` (50+ effects) → `ppt_set_slide_transition`
- **Layout**: `ppt_align_shapes`, `ppt_distribute_shapes`, `ppt_merge_shapes`
- **Icons**: `ppt_add_svg_icon` (2500+ Material Symbols) → `ppt_search_icons`
- **Typography**: `ppt_check_typography` (auto-fix widow lines, shrunk text)

## Design Principles
- Set a bold color palette FIRST with `ppt_set_theme_colors` (don't default to blue)
- Every slide needs a visual element: image, chart, icon, SmartArt, or shape
- Don't repeat the same layout on consecutive slides
- Typography: Title 36-44pt bold, Body 14-16pt, Captions 10-12pt
- Use two-column, icon+text, grid, or half-bleed image layouts for variety

## QA
After editing, use `ppt_get_slide_preview` on modified slides for visual verification.
Check for: overlapping elements, text overflow, low-contrast text, misaligned columns.
