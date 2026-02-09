/**
 * @claude-mem/opencode-plugin
 *
 * OpenCode plugin that replicates claude-mem's 8 Claude Code hooks using
 * OpenCode's 16 hook points. Captures session lifecycle, tool executions,
 * and compaction events, and injects memory context into the system prompt.
 *
 * Design principles:
 * - Stateless: no local DB, all state lives in the claude-mem backend
 * - Fire-and-forget: POSTs never block the harness on failure
 * - Fail-open: all hooks silently degrade when backend is unreachable
 */

import type { Plugin, Hooks } from '@opencode-ai/plugin';
import type { Event } from '@opencode-ai/sdk';
import { ClaudeMemClient } from './client.js';
import { SessionMapper } from './session-mapper.js';
import { containsSecrets, redactSecrets } from './secret-detector.js';

/**
 * Tools that should be ignored (internal routing, no actionable content).
 */
const IGNORED_TOOLS = new Set([
  'ListMcpResourcesTool',
  'SlashCommand',
  'Skill',
  'AskFollowupQuestion',
]);

/**
 * Prefix for claude-mem's own MCP tools (avoid circular observations).
 */
const CLAUDE_MEM_MCP_PREFIX = 'mcp__plugin_claude-mem_';

/**
 * Task management tools.
 */
const TASK_TOOLS = new Set(['TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet']);

/**
 * Plan mode tools.
 */
const PLAN_MODE_TOOLS = new Set(['EnterPlanMode', 'ExitPlanMode']);

/**
 * Context response from backend.
 */
interface ContextResponse {
  context: string;
  observationCount: number;
  tokens: number;
}

/**
 * Check if a tool should be captured.
 */
function shouldCapture(toolName: string): boolean {
  if (IGNORED_TOOLS.has(toolName)) return false;
  if (toolName.startsWith(CLAUDE_MEM_MCP_PREFIX)) return false;
  return true;
}

/**
 * Detect CAPSLOCK-heavy text (urgency indicator).
 * Returns true if >70% of alpha characters are uppercase.
 */
function isUrgent(text: string): boolean {
  if (!text || text.length < 10) return false;
  const alpha = text.replace(/[^a-zA-Z]/g, '');
  if (alpha.length < 5) return false;
  const upper = alpha.replace(/[^A-Z]/g, '').length;
  return upper / alpha.length > 0.7;
}

/**
 * Extract sessionID from an Event based on its type.
 * Different event types carry the sessionID in different places.
 */
function extractSessionID(event: Event): string | undefined {
  const props = event.properties as Record<string, unknown>;
  // Most events have sessionID directly
  if (typeof props.sessionID === 'string') return props.sessionID;
  // Session lifecycle events carry info.id
  if (props.info && typeof (props.info as Record<string, unknown>).id === 'string') {
    return (props.info as Record<string, unknown>).id as string;
  }
  return undefined;
}

/**
 * Plugin entry point.
 */
export const ClaudeMemPlugin: Plugin = async (pluginInput) => {
  const client = new ClaudeMemClient();
  const sessions = new SessionMapper();
  const project = pluginInput.directory;

  // Periodically evict stale sessions (every 30 min)
  const evictionInterval = setInterval(() => sessions.evictStale(), 30 * 60 * 1000);
  // Ensure the timer doesn't prevent process exit
  if (evictionInterval.unref) evictionInterval.unref();

  const hooks: Hooks = {
    // =====================================================================
    // Hook 1: Session lifecycle via event bus
    // Maps to: session-start (session.created), session-end (session.idle/deleted)
    // Also handles: subagent-start/stop via message.part.updated events
    // =====================================================================
    event: async ({ event }) => {
      const type = event.type;

      // --- Session created → init session in backend ---
      if (type === 'session.created') {
        const sessionID = event.properties.info.id;
        if (sessionID) {
          sessions.register(sessionID, project, pluginInput.directory);
          void client.post('/api/hooks/session-init', {
            sessionId: sessionID,
            project,
            cwd: pluginInput.directory,
            harness: 'opencode',
          });
        }
      }

      // --- Session idle → end session in backend ---
      if (type === 'session.idle') {
        const sessionID = event.properties.sessionID;
        if (sessionID) {
          void client.post('/api/hooks/session/end', {
            sessionId: sessionID,
            project,
            reason: 'idle',
          });
        }
      }

      // --- Session deleted → end session in backend ---
      if (type === 'session.deleted') {
        const sessionID = event.properties.info.id;
        if (sessionID) {
          void client.post('/api/hooks/session/end', {
            sessionId: sessionID,
            project,
            reason: 'deleted',
          });
          sessions.remove(sessionID);
        }
      }

      // --- Subagent lifecycle approximation via message.part.updated ---
      if (type === 'message.part.updated') {
        const part = event.properties.part;
        const sessionID = extractSessionID(event);

        if (part && sessionID) {
          // Subtask part = subagent start
          if (part.type === 'subtask') {
            void client.post('/api/hooks/subagent/start', {
              sessionId: sessionID,
              project,
              subagentType: part.agent || 'unknown',
              prompt: part.prompt || part.description || '',
            });
          }

          // StepFinish = subagent stop approximation
          if (part.type === 'step-finish') {
            void client.post('/api/hooks/subagent/stop', {
              sessionId: sessionID,
              project,
              subagentType: 'unknown',
              status: 'completed',
            });
          }
        }
      }
    },

    // =====================================================================
    // Hook 2: User prompt capture via chat.message
    // Maps to: user-prompt-submit
    // =====================================================================
    'chat.message': async (input, output) => {
      // The user message is in output.message; input has sessionID
      const sessionID = input.sessionID;
      if (!sessionID) return;

      // Extract text from parts
      let text = '';
      if (output.parts) {
        for (const part of output.parts) {
          if (part.type === 'text' && 'text' in part) {
            text += part.text;
          }
        }
      }

      // Secret detection — redact before sending
      if (containsSecrets(text)) {
        text = redactSecrets(text);
      }

      // Urgency detection (CAPSLOCK)
      const urgent = isUrgent(text);

      void client.post('/api/hooks/user-prompt-submit', {
        sessionId: sessionID,
        project,
        prompt: text,
        urgent,
        harness: 'opencode',
      });
    },

    // =====================================================================
    // Hook 3: Tool execution capture
    // Maps to: post-tool-use (observations, task tools, plan mode)
    // =====================================================================
    'tool.execute.after': async (input, output) => {
      const toolName = input.tool;
      const sessionID = input.sessionID;

      if (!toolName || !shouldCapture(toolName) || !sessionID) return;

      // output.metadata may contain the tool args from before execution
      const toolInput = typeof output.metadata === 'object'
        ? JSON.stringify(output.metadata)
        : '{}';
      const toolOutput = output.output || '';

      // --- Task tools (TaskCreate, TaskUpdate) ---
      if (TASK_TOOLS.has(toolName) && typeof output.metadata === 'object' && output.metadata) {
        const args = output.metadata as Record<string, unknown>;
        if (toolName === 'TaskCreate') {
          void client.post('/api/hooks/user-task/create', {
            sessionId: sessionID,
            project,
            title: args.subject,
            description: args.description,
            activeForm: args.activeForm,
            sourceMetadata: args.metadata,
          });
        } else if (toolName === 'TaskUpdate') {
          void client.post('/api/hooks/user-task/update', {
            sessionId: sessionID,
            project,
            externalId: args.taskId,
            title: args.subject,
            description: args.description,
            activeForm: args.activeForm,
            status: args.status,
            owner: args.owner,
            blockedBy: args.addBlockedBy,
            blocks: args.addBlocks,
            sourceMetadata: args.metadata,
          });
        }
      }

      // --- Plan mode tools ---
      if (PLAN_MODE_TOOLS.has(toolName)) {
        if (toolName === 'EnterPlanMode') {
          void client.post('/api/hooks/plan-mode/enter', {
            sessionId: sessionID,
            project,
          });
        } else if (toolName === 'ExitPlanMode') {
          void client.post('/api/hooks/plan-mode/exit', {
            sessionId: sessionID,
            project,
            approved: true,
          });
        }
      }

      // --- Secret detection on tool I/O ---
      let safeInput = toolInput;
      let safeOutput = toolOutput;
      if (containsSecrets(safeInput)) safeInput = redactSecrets(safeInput);
      if (containsSecrets(safeOutput)) safeOutput = redactSecrets(safeOutput);

      // --- General observation ---
      void client.post('/api/hooks/observation', {
        sessionId: sessionID,
        project,
        toolName,
        toolInput: safeInput,
        toolOutput: safeOutput,
        cwd: pluginInput.directory,
      });
    },

    // =====================================================================
    // Hook 4: Context injection via system prompt transform
    // Maps to: session-start context injection
    // =====================================================================
    'experimental.chat.system.transform': async (_input, output) => {
      try {
        const ready = await client.isReady();
        if (!ready) return;

        const ctx = await client.get<ContextResponse>('/api/hooks/context', {
          project,
        });

        if (ctx.context && ctx.observationCount > 0) {
          const contextBlock = [
            '',
            '<claude-mem-context>',
            '# Recent Activity',
            '',
            '<!-- This section is auto-generated by claude-mem. -->',
            '',
            ctx.context,
            '</claude-mem-context>',
          ].join('\n');

          // output.system is string[] — append our context block
          output.system.push(contextBlock);
        }
      } catch {
        // Fail-open: don't modify system prompt on error
      }
    },

    // =====================================================================
    // Hook 5: Pre-compaction hook
    // Maps to: pre-compact
    // =====================================================================
    'experimental.session.compacting': async (input, output) => {
      const sessionID = input.sessionID;
      if (!sessionID) return;

      try {
        const result = (await client.post('/api/hooks/pre-compact', {
          sessionId: sessionID,
          project,
        })) as { context?: string } | null;

        // If backend returns context to preserve, inject it into compaction
        if (result?.context) {
          output.context.push(result.context);
        }
      } catch {
        // Fail-open
      }
    },
  };

  return hooks;
};

// Default export for OpenCode plugin resolution
export default ClaudeMemPlugin;
