"use strict";

// One call to the OpenAI Chat Completions API with a strict JSON schema, over
// plain fetch. Throws UpstreamError on anything that is not a parsed object.

const CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

// kind: "timeout" | "network" | "http" | "refused" | "truncated" | "malformed"
class UpstreamError extends Error {
  constructor(kind, httpStatus) {
    super(httpStatus ? `upstream ${kind} ${httpStatus}` : `upstream ${kind}`);
    this.name = "UpstreamError";
    this.kind = kind;
    this.httpStatus = httpStatus;
  }
}

async function completeJson({
  fetch,
  apiKey,
  model,
  reasoningEffort,
  messages,
  schemaName,
  schema,
  maxCompletionTokens,
  timeoutMs,
}) {
  const payload = {
    model,
    messages,
    response_format: {
      type: "json_schema",
      json_schema: { name: schemaName, strict: true, schema },
    },
    max_completion_tokens: maxCompletionTokens,
    store: false,
  };
  // Only for reasoning models; others reject the field (see README).
  if (reasoningEffort) payload.reasoning_effort = reasoningEffort;

  const signal = AbortSignal.timeout(timeoutMs);
  let response;
  let data;
  try {
    response = await fetch(CHAT_COMPLETIONS_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(payload),
      signal,
    });
    if (!response.ok) {
      // Free the connection; the error body is not logged.
      if (response.body) await response.body.cancel().catch(() => {});
      throw new UpstreamError("http", response.status);
    }
    data = await response.json();
  } catch (err) {
    if (err instanceof UpstreamError) throw err;
    if (signal.aborted) throw new UpstreamError("timeout");
    throw new UpstreamError(response ? "malformed" : "network");
  }

  const choice = data && Array.isArray(data.choices) ? data.choices[0] : undefined;
  const message = choice && choice.message;
  if (!message) throw new UpstreamError("malformed");
  if (message.refusal) throw new UpstreamError("refused");
  if (choice.finish_reason === "length") throw new UpstreamError("truncated");

  let value;
  try {
    value = JSON.parse(message.content);
  } catch {
    throw new UpstreamError("malformed");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new UpstreamError("malformed");
  }

  const usage = data.usage || {};
  return {
    value,
    usage: { promptTokens: usage.prompt_tokens, completionTokens: usage.completion_tokens },
  };
}

module.exports = { completeJson, UpstreamError, CHAT_COMPLETIONS_URL };
