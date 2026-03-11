

# The Linkage-Engine


### The Problem
"Genealogical data is messy. Traditional 'exact match' logic fails when names change, dates are approximate, or records are sparse. Most systems give you a list of results; they don't give you a degree of certainty."

### The Solution
"I'm developing **linkage-engine** to solve the fundamental problem of entity resolution in messy, sparse datasets. It's a Spring Boot service that uses LLMs and vector embeddings to find semantic overlaps between names, family structures, and even photos. The LLM attempts to make semantic connections between records—names, events, locations, and documents—and reports a **degree of confidence** for each suggested link."

### AI for Semantic Connections
The LLM attempts to make semantic connections between historical records 
which may include names, families, events, dates, locations, photos, 
and other documents and reports a degree of confidence for each.

### More than a search bar
"It’s more than a search bar; it's a **'Truth Engine.'** It validates if a person's life events are physically possible across time and space. For Ancestry, this means moving from just 'finding records' to 'validating stories' using high-dimensional similarity and RAG (Retrieval Augmented Generate)."

### Human in the Loop
These "Confidence Scores" and "Supporting Evidences" are used to automatically surface the highest-probability leads. Humans make the final call as to
which connections get marked as legitimate.

### Technical Depth
* **Java 21 & Spring Boot 3.4:** Leveraging Java 21's ability to handle massive I/O for vector DBs.
* **Probabilistic Matching:** Moving from deterministic SQL to vector-based similarity using `pgvector`.
* **Data Integrity:** Strict null-safety analysis to handle the sparse data inherent in historical archives.
* **Idempotent Ingestion:**	Proves you won't create duplicate records if a Lambda retries.
* **Hybrid Search:**	Combining SQL metadata filters (e.g., year > 1800) with Vector Similarity.
* **Context Window:**	Explaining why you chunk data into 500 tokens (to avoid LLM "forgetting").
* **Cosine Similarity:**	The mathematical basis for how you "resolve" two different names.
* **Dimensionality Reduction:**  With Matryoshka Embeddings the model is trained specifically so that the most semantically similar features are stored in the earlier indices of the vector. So vector dimensionality can be reduced with simple truncation, leaving the most distinguishing dimensions intact.
