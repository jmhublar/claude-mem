/**
 * HTTP client for claude-mem backend.
 *
 * Stateless, fire-and-forget design. All POSTs are non-blocking:
 * failures are silently logged, never blocking the harness.
 */

const DEFAULT_URL = 'http://localhost:38888';
const DEFAULT_TIMEOUT_MS = 5000;
const HEALTH_TIMEOUT_MS = 2000;

export interface ClientConfig {
  baseUrl: string;
  authToken: string;
  timeout?: number;
}

export class ClaudeMemClient {
  private readonly baseUrl: string;
  private readonly authToken: string;
  private readonly timeout: number;

  constructor(config?: Partial<ClientConfig>) {
    this.baseUrl = (config?.baseUrl || process.env.CLAUDE_MEM_URL || DEFAULT_URL).replace(
      /\/$/,
      '',
    );
    this.authToken = config?.authToken || process.env.CLAUDE_MEM_REMOTE_TOKEN || '';
    this.timeout = config?.timeout || DEFAULT_TIMEOUT_MS;
  }

  /**
   * Quick health check — returns true if backend is reachable and core-ready.
   */
  async isReady(): Promise<boolean> {
    try {
      const res = await this.fetch('/api/health', { timeout: HEALTH_TIMEOUT_MS });
      if (!res.ok) return false;
      const data = (await res.json()) as { coreReady?: boolean };
      return data.coreReady === true;
    } catch {
      return false;
    }
  }

  /**
   * GET with query params.
   */
  async get<T>(path: string, params?: Record<string, string>): Promise<T> {
    const url = new URL(path, this.baseUrl);
    if (params) {
      for (const [k, v] of Object.entries(params)) {
        url.searchParams.set(k, v);
      }
    }
    const res = await this.fetch(url.pathname + url.search);
    if (!res.ok) throw new Error(`GET ${path} failed: ${res.status}`);
    return (await res.json()) as T;
  }

  /**
   * Fire-and-forget POST. Resolves to the response body on success, null on failure.
   * Never throws — failures are swallowed to avoid blocking the harness.
   */
  async post(path: string, body: unknown): Promise<unknown> {
    try {
      const res = await this.fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) return null;
      return await res.json();
    } catch {
      return null;
    }
  }

  private async fetch(
    path: string,
    options: RequestInit & { timeout?: number } = {},
  ): Promise<Response> {
    const url = path.startsWith('http') ? path : `${this.baseUrl}${path}`;
    const timeout = options.timeout || this.timeout;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);

    try {
      const headers: Record<string, string> = {
        ...((options.headers as Record<string, string>) || {}),
      };
      if (this.authToken) {
        headers['Authorization'] = `Bearer ${this.authToken}`;
      }
      return await fetch(url, { ...options, headers, signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
  }
}
