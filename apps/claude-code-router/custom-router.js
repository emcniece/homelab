// CCR custom router (Config > CUSTOM_ROUTER_PATH). CCR runs it before every
// other route, including the built-in sub-agent route. Returning a
// "Provider/model" string pins the request; returning undefined falls through
// to normal routing.
//
// Installed by copying into the ccr-data PVC (see README.md). CCR re-reads
// the file on every request, so edits take effect without a restart.

const SUBSCRIPTION_PROVIDER = 'Claude Code API';

// 1. Auto-mode safety classifier. It sends the session transcript, which
// quotes Agent tool calls including their <CCR-SUBAGENT-MODEL> tag. CCR looks
// for that tag anywhere in the system prompt or first two user messages, so
// without this it routed the classifier to the local sub-agent model (qwen3
// answered in prose, hit max_tokens, and every check was retried).
// Keep the model the classifier asked for (claude-sonnet-5 as of Claude Code
// 2.1.325): it sends thinking: {type: "disabled"}, which claude-sonnet-5-5
// rejects with HTTP 400.
const CLASSIFIER_MARKER = 'You are a security monitor for autonomous AI coding agents';
const CLASSIFIER_DEFAULT_MODEL = 'claude-sonnet-5';

// 2. Main-session model selection. CCR's built-in Claude Code route sends
// every request to the profile's default model, ignoring /model. Requests for
// a model the subscription provider lists keep that model. Anything else
// (unknown models, Ollama selectors) falls through to CCR's routing.
const SUBAGENT_TAG = /^\s*<CCR-SUBAGENT-MODEL>/;

function blockText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((b) => (typeof b === 'string' ? b : b?.text || '')).join('\n');
  }
  return '';
}

function isClaudeCode(req) {
  return String(req.headers?.['user-agent'] || '').toLowerCase().includes('claude');
}

// A real sub-agent request starts its first user message with the tag.
function isSubagent(body) {
  const first = Array.isArray(body?.messages) ? body.messages.find((m) => m?.role === 'user') : undefined;
  return SUBAGENT_TAG.test(blockText(first?.content));
}

module.exports = async function router(req, config) {
  const body = req.body || {};
  const provider = config?.Providers?.find((p) => p.name === SUBSCRIPTION_PROVIDER);
  if (!provider || provider.enabled === false) return undefined;
  const requested = typeof body.model === 'string' ? body.model.replace(/\[1m\]$/i, '').trim() : '';
  const listed = provider.models?.includes(requested);

  if (blockText(body.system).includes(CLASSIFIER_MARKER)) {
    return `${SUBSCRIPTION_PROVIDER}/${listed ? requested : CLASSIFIER_DEFAULT_MODEL}`;
  }
  if (listed && isClaudeCode(req) && !isSubagent(body)) {
    return `${SUBSCRIPTION_PROVIDER}/${requested}`;
  }
  return undefined;
};
