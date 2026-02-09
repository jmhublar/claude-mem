/**
 * Session ID mapper — bidirectional mapping between OpenCode session IDs
 * and claude-mem session IDs.
 *
 * OpenCode sessions use their own UUID format. claude-mem's backend
 * accepts any string sessionId, so we pass OpenCode's IDs directly.
 * This module tracks active sessions and their metadata for context.
 */

export interface SessionInfo {
  openCodeId: string;
  project: string;
  directory: string;
  createdAt: number;
  promptCounter: number;
}

export class SessionMapper {
  private sessions = new Map<string, SessionInfo>();

  /**
   * Register a new session.
   */
  register(openCodeId: string, project: string, directory: string): void {
    this.sessions.set(openCodeId, {
      openCodeId,
      project,
      directory,
      createdAt: Date.now(),
      promptCounter: 0,
    });
  }

  /**
   * Get session info by OpenCode session ID.
   */
  get(openCodeId: string): SessionInfo | undefined {
    return this.sessions.get(openCodeId);
  }

  /**
   * Increment and return the next prompt number for a session.
   */
  incrementPrompt(openCodeId: string): number {
    const info = this.sessions.get(openCodeId);
    if (!info) {
      return 1;
    }
    info.promptCounter += 1;
    return info.promptCounter;
  }

  /**
   * Remove a session (on session end/delete).
   */
  remove(openCodeId: string): void {
    this.sessions.delete(openCodeId);
  }

  /**
   * List all active sessions.
   */
  list(): SessionInfo[] {
    return Array.from(this.sessions.values());
  }

  /**
   * Evict sessions older than maxAge ms (default: 24h).
   * Call periodically to prevent unbounded memory growth.
   */
  evictStale(maxAgeMs = 24 * 60 * 60 * 1000): number {
    const cutoff = Date.now() - maxAgeMs;
    let evicted = 0;
    for (const [id, info] of this.sessions) {
      if (info.createdAt < cutoff) {
        this.sessions.delete(id);
        evicted++;
      }
    }
    return evicted;
  }
}
