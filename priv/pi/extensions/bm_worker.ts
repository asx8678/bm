/**
 * BM worker tools. Load only in worker profiles.
 *
 * `submit_result` reports the outcome of the worker's current attempt. The BEAM binds it to the
 * attempt assigned to this pi process (not to anything the model says), persists it and replies.
 * "Received" is not "accepted": the BEAM accepts work only after settling and verification.
 */

import { StringEnum, Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bmRequest, registerShutdown, report } from "./bm_common.ts";

const submitResult = defineTool({
	name: "submit_result",
	label: "Submit result",
	description: "Report the outcome of your assigned task to BM. Call it exactly once, as your last action.",
	parameters: Type.Object({
		status: StringEnum(["done", "blocked", "failed"] as const),
		summary: Type.String({ description: "What you changed or found, in at most five sentences." }),
		files_changed: Type.Optional(Type.Array(Type.String())),
	}),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		const reply = await bmRequest(ctx, "submit_result", params);
		return {
			content: [{ type: "text", text: `Result ${String(reply.status ?? "received")} by BM.` }],
			details: { status: params.status },
			// The worker has nothing left to do after reporting.
			terminate: true,
		};
	},
});

export default function (pi: ExtensionAPI) {
	registerShutdown(pi);
	pi.registerTool(submitResult);
	pi.on("session_start", (_event, ctx) => report(ctx, "profile", { role: "worker", tools: pi.getActiveTools() }));
}
