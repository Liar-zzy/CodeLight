/**
 * Relay HTTP routes — handles events from remote codeisland-relay daemons.
 *
 * These routes are additive: they do NOT modify any existing route files.
 * The relay acts as a "virtual Mac" device, forwarding hook events and JSONL
 * messages from remote Claude Code sessions to the CodeLight backend.
 */

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db } from '@/storage/db';
import { authMiddleware } from '@/auth/authMiddleware';
import { allocateSessionSeq } from '@/storage/seq';
import { eventRouter } from '@/socket/socketServer';

// In-memory command queue: deviceId → pending commands
const commandQueues = new Map<string, Array<{ type: string; [key: string]: unknown }>>();

export function queueRelayCommand(deviceId: string, command: { type: string; [key: string]: unknown }) {
    if (!commandQueues.has(deviceId)) {
        commandQueues.set(deviceId, []);
    }
    commandQueues.get(deviceId)!.push(command);
}

export async function relayRoutes(app: FastifyInstance) {
    // POST /v1/relay/event — relay sends hook events and JSONL messages
    app.post('/v1/relay/event', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                type: z.string(),
                data: z.record(z.unknown()),
            }),
        },
    }, async (request, reply) => {
        const deviceId = (request as any).deviceId as string;
        const { type, data } = request.body as { type: string; data: Record<string, unknown> };

        if (type === 'hook_event') {
            return await handleHookEvent(deviceId, data);
        }
        if (type === 'jsonl_message') {
            return await handleJsonlMessage(deviceId, data);
        }
        if (type === 'permission_request') {
            return await handlePermissionRequest(deviceId, data);
        }
        return { ok: true };
    });

    // GET /v1/relay/commands — relay polls for pending commands
    app.get('/v1/relay/commands', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const deviceId = (request as any).deviceId as string;
        const commands = commandQueues.get(deviceId) || [];
        commandQueues.delete(deviceId);
        return { commands };
    });

    // POST /v1/relay/focus — iPhone/CodeIsland triggers remote focus
    app.post('/v1/relay/focus', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                relayDeviceId: z.string(),
                sessionId: z.string(),
                mux_type: z.string(),
                mux_session: z.string(),
                tab_index: z.number().optional(),
                tmux_target: z.string().optional(),
            }),
        },
    }, async (request, reply) => {
        const body = request.body as {
            relayDeviceId: string;
            sessionId: string;
            mux_type: string;
            mux_session: string;
            tab_index?: number;
            tmux_target?: string;
        };

        queueRelayCommand(body.relayDeviceId, {
            type: 'focus-session',
            mux_type: body.mux_type,
            mux_session: body.mux_session,
            tab_index: body.tab_index,
            tmux_target: body.tmux_target,
        });

        eventRouter.emitToDevice(body.relayDeviceId, 'focus-session', {
            sessionId: body.sessionId,
            mux_type: body.mux_type,
            mux_session: body.mux_session,
            tab_index: body.tab_index,
        });

        return { ok: true };
    });

    // POST /v1/relay/launch — launch a new session on the remote server
    app.post('/v1/relay/launch', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                relayDeviceId: z.string(),
                cwd: z.string(),
                command: z.string().optional(),
                mux_type: z.string().optional(),
                mux_session: z.string().optional(),
            }),
        },
    }, async (request, reply) => {
        const body = request.body as {
            relayDeviceId: string;
            cwd: string;
            command?: string;
            mux_type?: string;
            mux_session?: string;
        };

        queueRelayCommand(body.relayDeviceId, {
            type: 'launch-session',
            cwd: body.cwd,
            command: body.command || 'claude',
            mux_type: body.mux_type || 'zellij',
            mux_session: body.mux_session,
        });

        return { ok: true };
    });

    // PATCH /v1/relay/sessions/:id/visibility — hide/show a session
    app.patch('/v1/relay/sessions/:id/visibility', {
        preHandler: authMiddleware,
        schema: {
            params: z.object({ id: z.string() }),
            body: z.object({ hidden: z.boolean() }),
        },
    }, async (request, reply) => {
        const { id } = request.params as { id: string };
        const { hidden } = request.body as { hidden: boolean };

        const updated = await db.remoteSessionMeta.updateMany({
            where: { sessionId: id },
            data: { hidden },
        });

        if (updated.count === 0) {
            return reply.code(404).send({ error: 'Not found' });
        }
        return { ok: true, hidden };
    });
}

// ---------------------------------------------------------------------------
// Event handlers
// ---------------------------------------------------------------------------

async function handleHookEvent(relayDeviceId: string, data: Record<string, unknown>) {
    const sessionTag = data.session_id as string;
    const cwd = data.cwd as string || '';
    const status = data.status as string;
    const remoteInfo = data.remote_info as Record<string, unknown> || {};

    const session = await db.session.upsert({
        where: { deviceId_tag: { deviceId: relayDeviceId, tag: sessionTag } },
        create: {
            tag: sessionTag,
            deviceId: relayDeviceId,
            metadata: JSON.stringify({
                path: cwd,
                projectName: cwd.split('/').filter(Boolean).pop() || 'Remote',
                sourceType: 'remote',
            }),
            active: status !== 'ended',
        },
        update: {
            active: status !== 'ended',
            lastActiveAt: new Date(),
        },
    });

    await db.remoteSessionMeta.upsert({
        where: { sessionId: session.id },
        create: {
            sessionId: session.id,
            host: (remoteInfo.host as string) || 'unknown',
            user: (remoteInfo.user as string) || 'unknown',
            muxType: (remoteInfo.mux_type as string) || 'unknown',
            muxSession: (remoteInfo.mux_session as string) || '',
            muxTabIndex: (remoteInfo.mux_tab_index as number) || null,
            remoteCwd: cwd,
            relayDeviceId,
        },
        update: {
            muxType: (remoteInfo.mux_type as string) || undefined,
            muxSession: (remoteInfo.mux_session as string) || undefined,
            muxTabIndex: (remoteInfo.mux_tab_index as number) || undefined,
            remoteCwd: cwd || undefined,
        },
    });

    const phaseMap: Record<string, string> = {
        'processing': 'thinking',
        'running_tool': 'tool_running',
        'waiting_for_approval': 'waiting_approval',
        'waiting_for_input': 'idle',
        'compacting': 'compacting',
        'ended': 'ended',
    };

    const phase = phaseMap[status] || status;
    const phaseMessage = JSON.stringify({
        type: 'phase',
        phase,
        toolName: data.tool || null,
        sourceType: 'remote',
    });

    const seq = await allocateSessionSeq(session.id);
    await db.sessionMessage.create({
        data: { sessionId: session.id, content: phaseMessage, seq },
    });

    eventRouter.emitUpdate(relayDeviceId, 'update', {
        type: 'new-message',
        sessionId: session.id,
        sessionTag,
        message: { seq, content: phaseMessage },
    }, { type: 'all-interested-in-session', sessionId: session.id });

    return { ok: true, sessionId: session.id };
}

async function handleJsonlMessage(relayDeviceId: string, data: Record<string, unknown>) {
    const sessionTag = data.session_id as string;
    const content = data.content as Record<string, unknown>;

    const session = await db.session.findUnique({
        where: { deviceId_tag: { deviceId: relayDeviceId, tag: sessionTag } },
    });
    if (!session) return { ok: false, error: 'Session not found' };

    const seq = await allocateSessionSeq(session.id);
    const messageContent = JSON.stringify(content);

    await db.sessionMessage.create({
        data: { sessionId: session.id, content: messageContent, seq },
    });

    eventRouter.emitUpdate(relayDeviceId, 'update', {
        type: 'new-message',
        sessionId: session.id,
        sessionTag,
        message: { seq, content: messageContent },
    }, { type: 'all-interested-in-session', sessionId: session.id });

    return { ok: true };
}

async function handlePermissionRequest(relayDeviceId: string, data: Record<string, unknown>) {
    // Forward as phase event so iPhone shows "Needs approval"
    await handleHookEvent(relayDeviceId, data);
    // For now, fall through to Claude Code's built-in UI
    return { decision: 'ask' };
}
