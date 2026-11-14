"""Provider-agnostic chat-model factory for the Safe Spot agents.

The `damage` and `voice` agents (Block 3) are built on LangChain / Deep Agents,
which take any LangChain chat model. This factory is the ONE place the provider
is chosen, so switching Ollama <-> Gemini <-> Bedrock is a single env var
(`MODEL_PROVIDER`) with no change to agent code.

    MODEL_PROVIDER=ollama   OLLAMA_MODEL=llama3.2            (free, local, default)
    MODEL_PROVIDER=gemini   GEMINI_MODEL=gemini-2.5-flash-lite  (+ GOOGLE_API_KEY)
    MODEL_PROVIDER=bedrock  BEDROCK_MODEL_ID=...             (+ AWS creds/region)

Imports are lazy so a missing provider package never breaks the app. NOTE: the
final provider choice edits DECISIONS.md and is Harini's to ratify; Ollama is the
free default for now. `langchain-ollama` must be installed to use it.
"""

from __future__ import annotations

import os
from typing import Any

DEFAULT_PROVIDER = "ollama"


def get_chat_model(provider: str | None = None, temperature: float = 0.0, **kwargs: Any):
    """Return a LangChain chat model for the configured provider."""
    provider = (provider or os.getenv("MODEL_PROVIDER") or DEFAULT_PROVIDER).lower()

    if provider == "ollama":
        from langchain_ollama import ChatOllama

        return ChatOllama(
            model=os.getenv("OLLAMA_MODEL", "llama3.2"),
            temperature=temperature,
            **kwargs,
        )

    if provider == "gemini":
        from langchain_google_genai import ChatGoogleGenerativeAI

        return ChatGoogleGenerativeAI(
            model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash-lite"),
            temperature=temperature,
            **kwargs,
        )

    if provider == "bedrock":
        from langchain_aws import ChatBedrockConverse

        return ChatBedrockConverse(
            model=os.getenv("BEDROCK_MODEL_ID"),
            region_name=os.getenv("AWS_REGION"),
            temperature=temperature,
            **kwargs,
        )

    raise ValueError(
        f"Unknown MODEL_PROVIDER {provider!r}; use ollama, gemini or bedrock"
    )
