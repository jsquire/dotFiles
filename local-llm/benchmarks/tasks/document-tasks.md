## Task: Technical Design Document

**Category:** document  
**Difficulty:** medium  
**Expected time:** 120s

### Prompt

> Create a Word document (.docx) for a "Network Segmentation Proposal" that includes:
> 1. Title page with document title, author "Jesse", date
> 2. Table of contents
> 3. Executive summary (2-3 paragraphs)
> 4. Current state diagram description (text-based network layout)
> 5. Proposed architecture with a table comparing current vs proposed VLANs
> 6. Implementation timeline as a table
> 7. Risk assessment with a 3-column table (Risk, Impact, Mitigation)
>
> Use the OfficeMCP server to create this document.

### Expected Outcome

Well-structured .docx with proper heading hierarchy (H1/H2/H3), tables with headers, professional formatting.  Content should be plausible and internally consistent.

### Scoring

- **Pass:** All 7 sections present, tables formatted correctly, heading hierarchy logical
- **Partial:** Content complete but formatting issues (e.g., no heading styles)
- **Fail:** Missing sections or broken document structure

---

## Task: Project Status Presentation

**Category:** document  
**Difficulty:** hard  
**Expected time:** 180s

### Prompt

> Create a PowerPoint deck (.pptx) for a quarterly IT infrastructure review with:
> 1. Title slide: "Q3 Infrastructure Review" with subtitle "IT Operations"
> 2. Agenda slide (bullet list of topics)
> 3. Uptime metrics slide with a text-based table showing 5 services and their uptime %
> 4. Incident summary slide with key incidents in bullet points
> 5. Budget slide with a table: category, budgeted, actual, variance
> 6. Next quarter priorities (numbered list)
> 7. Q&A slide
>
> Use the MCP PowerPoint server.

### Expected Outcome

7 slides with appropriate layouts, consistent formatting, tables where specified, professional tone.

### Scoring

- **Pass:** All 7 slides present, content appropriate, tables/lists formatted
- **Partial:** Slides present but formatting inconsistent or a slide is weak
- **Fail:** Missing slides or content nonsensical

---

## Task: Runbook Document

**Category:** document  
**Difficulty:** medium  
**Expected time:** 90s

### Prompt

> Write a Markdown runbook for "Ollama Model Update Procedure" that includes:
> 1. Prerequisites checklist
> 2. Pre-update verification steps (check current model, confirm VRAM)
> 3. Step-by-step update procedure with exact commands
> 4. Post-update validation
> 5. Rollback procedure
> 6. Troubleshooting section with common issues
>
> Output as a .md file suitable for the dotfiles repository.

### Expected Outcome

Clear numbered steps, exact commands (not pseudo-commands), covers error scenarios, rollback is actually workable.

### Scoring

- **Pass:** All sections complete, commands are real and correct, rollback works
- **Partial:** Mostly correct but some commands are pseudo-code
- **Fail:** Missing sections or commands that would fail
