## Task: Architecture Trade-off Analysis

**Category:** reasoning  
**Difficulty:** hard  
**Expected time:** 120s

### Prompt

> Compare three approaches for adding full-text search to a 50GB PostgreSQL database with 200M rows:
> 1. PostgreSQL native `tsvector` + GIN index
> 2. Elasticsearch sidecar with CDC sync
> 3. pgvector with embedding-based semantic search
>
> For each, analyze: query latency, indexing overhead, operational complexity, accuracy for typos/synonyms, infrastructure cost.  Recommend one for a 3-person team maintaining a SaaS product.

### Expected Outcome

Balanced analysis that acknowledges trade-offs rather than declaring a clear winner in all dimensions.  Recommendation should cite team size and operational burden as deciding factors.

### Scoring

- **Pass:** All three analyzed across all dimensions, recommendation is well-justified, nuanced
- **Partial:** Analysis correct but missing a dimension or recommendation is too simplistic
- **Fail:** Incorrect technical claims or missing an approach

---

## Task: Debugging Logic Puzzle

**Category:** reasoning  
**Difficulty:** hard  
**Expected time:** 90s

### Prompt

> A distributed system has three services: A → B → C.  Service A sends a request to B, which calls C.  The following symptoms are observed:
> - 5% of requests from A to B timeout after 30s
> - B's P99 latency to C is 2s (well within timeout)
> - B's CPU and memory are normal
> - C's response times are consistently under 500ms
> - B's connection pool to C has max_size=10
> - A sends ~200 requests/second to B
>
> What is the most likely root cause?  Explain your reasoning step by step.

### Expected Outcome

Identifies connection pool exhaustion in B (10 connections × ~0.5s = max 20 req/s throughput to C, but 200 req/s arrives from A).  Queued requests timeout.  Should recommend increasing pool size or adding backpressure.

### Scoring

- **Pass:** Correct root cause (pool exhaustion), clear step-by-step reasoning, actionable fix
- **Partial:** Identifies connection pool issue but math is wrong or explanation unclear
- **Fail:** Wrong root cause (e.g., blames network, C, or A)

---

## Task: Security Threat Model

**Category:** reasoning  
**Difficulty:** medium  
**Expected time:** 90s

### Prompt

> Threat model the following setup: Ollama running on a home server with `OLLAMA_HOST=0.0.0.0`, accessible on the LAN at port 11434, no authentication.  The home network uses a consumer router with default settings.  What are the attack vectors, and what mitigations would you recommend?

### Expected Outcome

Covers: unauthenticated API access, model poisoning, prompt injection via API, lateral movement if server compromised, DNS rebinding, port forwarding risks.  Mitigations: firewall rules, reverse proxy with auth, VLAN isolation, disable unused Ollama endpoints.

### Scoring

- **Pass:** 4+ attack vectors with specific mitigations, prioritized by risk
- **Partial:** 2-3 vectors, mitigations are generic ("use a firewall")
- **Fail:** Misses obvious vectors or suggests insecure mitigations

---

## Task: Cost-Benefit Analysis

**Category:** reasoning  
**Difficulty:** medium  
**Expected time:** 60s

### Prompt

> Should a solo developer running local LLMs upgrade from an RTX 4090 (24GB) to an RTX 5090 (32GB) for $2,000?  They currently run Qwen 27B Q3_K_M and want to run Q5_K_M.  They use AI coding assistance ~4 hours/day.  The 4090 would be sold for ~$1,200 (net cost ~$800).  Frame as a quantitative cost-benefit analysis.

### Expected Outcome

Quantifies: quality improvement (Q3→Q5), time savings from better output, cost per month amortized over GPU lifespan, compares with cloud alternative cost.  Conclusion should be nuanced (e.g., "marginal quality gain doesn't justify cost unless also gaming/rendering").

### Scoring

- **Pass:** Quantitative analysis with numbers, considers alternatives, nuanced conclusion
- **Partial:** Correct framing but no actual numbers
- **Fail:** Pure opinion without analysis
