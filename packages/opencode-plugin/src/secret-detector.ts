/**
 * Secret detection — standalone port of @claude-mem/shared/secret-detector
 * for use in the OpenCode plugin without depending on the shared package.
 *
 * Detects API keys, passwords, tokens, and other sensitive strings.
 * Returns true if any secrets are found in the input text.
 */

const SECRET_PATTERNS: RegExp[] = [
  // API keys
  /sk-[a-zA-Z0-9]{20,}/g,
  /sk-ant-[a-zA-Z0-9-]{20,}/g,
  /AKIA[0-9A-Z]{16}/g,
  /ghp_[a-zA-Z0-9]{36}/g,
  /gho_[a-zA-Z0-9]{36}/g,
  /glpat-[a-zA-Z0-9-]{20}/g,

  // AWS secrets
  /aws_secret_access_key\s*[=:]\s*['"]?[A-Za-z0-9/+=]{40}['"]?/gi,

  // Generic credentials
  /(?:password|passwd|pwd)\s*[=:]\s*['"]?[^\s'"]{4,}['"]?/gi,
  /(?:secret|token)\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/gi,

  // Connection strings with embedded passwords
  /mongodb(?:\+srv)?:\/\/[^:]+:[^@]+@[^\s]+/gi,
  /postgres(?:ql)?:\/\/[^:]+:[^@]+@[^\s]+/gi,
  /mysql:\/\/[^:]+:[^@]+@[^\s]+/gi,
  /redis:\/\/[^:]+:[^@]+@[^\s]+/gi,

  // Private keys
  /-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----/g,

  // JWT tokens
  /eyJ[a-zA-Z0-9_-]{10,}\.eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}/g,

  // Env-style key assignments
  /[A-Z_]+_API_KEY\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/g,
  /[A-Z_]+_SECRET\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/g,
  /[A-Z_]+_TOKEN\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/g,

  // Bearer / Basic auth
  /Bearer\s+[a-zA-Z0-9_-]{20,}/g,
  /Basic\s+[a-zA-Z0-9+/=]{20,}/g,
];

/**
 * Returns true if the text contains any known secret patterns.
 */
export function containsSecrets(text: string): boolean {
  if (!text) return false;
  for (const pattern of SECRET_PATTERNS) {
    pattern.lastIndex = 0;
    if (pattern.test(text)) return true;
  }
  return false;
}

/**
 * Redact secrets in text, replacing them with [REDACTED] markers.
 */
export function redactSecrets(text: string): string {
  if (!text) return text;
  let result = text;
  for (const pattern of SECRET_PATTERNS) {
    const fresh = new RegExp(pattern.source, pattern.flags);
    result = result.replace(fresh, '[REDACTED]');
  }
  return result;
}
