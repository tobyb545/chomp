import rulesJson from "./rules.json" with { type: "json" };

/** Mirror of shared/rules.json (copied here by tools/sync-rules.sh; a test checks they match). */
export type Rules = typeof rulesJson;
export const rules: Rules = rulesJson;
export const decaySeconds = (r: Rules) => r.decay.days * 86_400;
