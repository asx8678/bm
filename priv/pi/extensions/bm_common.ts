/**
 * Shared helpers for BM's pi extensions (bm_planner, bm_worker, bm_guard). Not an extension itself.
 *
 * Two channels to the BEAM, both carried by pi's RPC extension-UI protocol:
 * - `bmRequest`: an input dialog titled `bm:<op>`. pi waits until the BEAM answers, and the BEAM
 *   persists the request before answering. Use it for anything authoritative.
 * - `report`: a `bm:`-prefixed notify record. Best-effort telemetry only.
 *
 * Both work for direct tool calls and for calls made inside Fabric's fabric_exec (nested calls
 * emit no RPC events of their own).
 */

import { randomUUID } from "node:crypto";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export const PROTOCOL_VERSION = 1;

export type BmReply = { ok: boolean; error?: string; [key: string]: unknown };

/** Sends an authoritative request and returns the BEAM's reply. Throws (fails closed) otherwise. */
export async function bmRequest(
	ctx: ExtensionContext | undefined,
	op: string,
	payload: unknown,
): Promise<BmReply> {
	if (!ctx?.ui?.input) throw new Error(`BM bridge unavailable for ${op}: no RPC client`);

	const request = { v: PROTOCOL_VERSION, op, request_id: randomUUID(), payload };
	const answer = await ctx.ui.input(`bm:${op}`, JSON.stringify(request));
	if (answer === undefined) throw new Error(`BM did not answer ${op}`);

	let reply: BmReply;
	try {
		reply = JSON.parse(answer);
	} catch {
		throw new Error(`BM sent an unreadable reply to ${op}`);
	}
	if (!reply.ok) throw new Error(`BM rejected ${op}: ${reply.error ?? "unknown reason"}`);
	return reply;
}

/** Best-effort telemetry. */
export function report(ctx: ExtensionContext | undefined, event: string, data: unknown): void {
	ctx?.ui?.notify(`bm:${JSON.stringify({ event, data })}`, "info");
}
